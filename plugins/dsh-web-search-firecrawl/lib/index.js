/**
 * Firecrawl-backed web search and fetch provider for the DeepSeek Harness web
 * capability seam (`ctx.web`). It registers a `WebSearchProvider` and a
 * `WebFetchProvider` under the stable id `firecrawl`, calling Firecrawl's v2
 * `/search` and `/scrape` endpoints respectively.
 *
 * Unlike the DeepSeek provider (which pays a full Anthropic-compatible Messages
 * model turn to get structured `web_search_tool_result` blocks), Firecrawl exposes a
 * dedicated retrieval endpoint: one search is one HTTP request returning plain JSON
 * result rows (`data.web[]`), which we map straight into the seam's normalized
 * `WebSearchSource` shape. One fetch is one `/scrape` request returning cleaned
 * markdown, mapped into the seam's `WebFetchResult` body. Cost is a handful of
 * Firecrawl credits, not model tokens.
 *
 * This is an **implementation** package: it registers providers into `ctx.web`,
 * resolves its credential for each operation through the optional `ctx.credentials`
 * seam, and does not register a model-facing tool. Like
 * `@deepseek-ai/dsh-web-search-deepseek` it is a function/namespace plugin
 * (`inject: ['web']`).
 *
 * @module dsh-web-search-firecrawl
 */
import z from "@deepseek-ai/schemastery";
import { credentialRef } from "@deepseek-ai/dsh-credentials";
import { installSettingsSection, settingsNamespace } from "@deepseek-ai/dsh-settings";
import { launchEnvironmentOf } from "@deepseek-ai/dsh-launch-environment";
import { WebError } from "@deepseek-ai/dsh-web";

/** Stable id this provider registers under. */
const FIRECRAWL_PROVIDER_ID = "firecrawl";

/** Hosted Firecrawl default base; `/v2/search` is appended. */
const FIRECRAWL_DEFAULT_BASE_URL = "https://api.firecrawl.dev";

/** Default number of web results one search returns (mirrors tool-web's searchMaxResults default). */
const FIRECRAWL_DEFAULT_MAX_RESULTS = 8;

/** Default per-search HTTP timeout budget (ms). */
const FIRECRAWL_DEFAULT_TIMEOUT_MS = 30000;

/** Scrape formats requested for `web_fetch`; Firecrawl's cleaned markdown maps to `WebFetchBody.kind: "text"`. */
const FIRECRAWL_FETCH_FORMATS = ["markdown"];

/** Attribution header sent on every request. */
const USER_AGENT = "deepseek-harness-firecrawl/0.1.0";

/** Cordis plugin name used by loader diagnostics. */
const name = "web-search-firecrawl";

/** The web seam this provider registers into. */
const inject = ["web"];

/** Credential reference (env name) naming the Firecrawl API key. */
const DEFAULT_API_KEY_ENV = "FIRECRAWL_API_KEY";

/** Environment variable naming this provider's endpoint (self-hosted Firecrawl). */
const SEARCH_BASE_URL_ENV = "FIRECRAWL_API_URL";

/** Settings namespace carrying this provider's endpoint, result cap, and key reference. */
const WEB_SEARCH_FIRECRAWL_SETTINGS_NAMESPACE = settingsNamespace("web-search-firecrawl");

/** Config schema for the `web-search-firecrawl` row. */
const Config = z.object({
	apiKey: z.string().role("secret"),
	apiKeyEnv: z.string().role("credential-ref").default(DEFAULT_API_KEY_ENV),
	baseURL: z.string(),
	maxResults: z.number().step(1).min(1).default(FIRECRAWL_DEFAULT_MAX_RESULTS),
	timeoutMs: z.number().step(1).min(1).default(FIRECRAWL_DEFAULT_TIMEOUT_MS)
});

/**
 * Map a Firecrawl v2 `/search` response body to a normalized search result.
 * Walks `data.web[]` items (`url`, `title`, `description`) into `sources[]`,
 * dedupes by URL, and drops items without a URL. Web results carry no date, so
 * `publishedAt` is left absent rather than invented. The web service owns the
 * final `maxResults` truncation, so `truncated` is always `false` here.
 *
 * @param data - the parsed `data` object of the search response.
 * @returns the normalized result with deduped sources.
 * @throws {@link WebError} when the response carries no usable results.
 */
function mapFirecrawlResponse(data) {
	const web = data?.web;
	if (Array.isArray(web) === false) {
		throw new WebError("Firecrawl search returned no data.web results; the response shape may have changed", "WEB_PROVIDER_ERROR");
	}
	const seen = new Set();
	const sources = [];
	for (const item of web) {
		if (typeof item?.url !== "string" || item.url.length === 0 || seen.has(item.url)) continue;
		seen.add(item.url);
		sources.push({
			url: item.url,
			...(typeof item.title === "string" && item.title.length > 0 ? { title: item.title } : {}),
			...(typeof item.description === "string" && item.description.length > 0 ? { snippet: item.description } : {})
		});
	}
	return { sources, truncated: false };
}

/**
 * Map a Firecrawl v2 `/scrape` response body to a normalized fetch result.
 * Walks `data` (`url`, `statusCode`, `markdown`, `metadata.statusCode`) into the
 * seam's `WebFetchResult` shape. Firecrawl's cleaned markdown maps to
 * `kind: "text"` — already-readable content, so `web_fetch` renders it verbatim
 * rather than running raw HTML through its own HTML→markdown conversion. The
 * provider does not cap the body here; the tool's `maxOutputChars` boundary owns
 * truncation, so `truncated` is always `false`.
 *
 * @param data - the parsed `data` object of the scrape response.
 * @param requestUrl - the requested URL, used when the response omits `url`.
 * @returns the normalized, untruncated fetch result.
 */
function mapFirecrawlScrapeResponse(data, requestUrl) {
	const markdown = typeof data?.markdown === "string" ? data.markdown : "";
	const url = typeof data?.url === "string" && data.url.length > 0 ? data.url : requestUrl;
	const statusCode = typeof data?.statusCode === "number"
		? data.statusCode
		: typeof data?.metadata?.statusCode === "number"
			? data.metadata.statusCode
			: 200;
	return {
		url,
		statusCode,
		body: { kind: "text", content: markdown },
		truncated: false
	};
}

/** The Firecrawl-backed search provider; HTTP redirects fail as `WEB_PROVIDER_ERROR`. */
class FirecrawlSearchProvider {
	resolveOptions;
	id = FIRECRAWL_PROVIDER_ID;

	/**
	 * @param resolveOptions - the options for the NEXT operation, snapshotted
	 * once at each operation's entry so one search never mixes two sections.
	 */
	constructor(resolveOptions) {
		this.resolveOptions = resolveOptions;
	}

	available() {
		const options = this.resolveOptions();
		return ((options.apiKey?.length ?? 0) > 0 || options.resolveApiKey !== void 0) && URL.canParse(options.baseURL) && isPositiveInteger(options.maxResults);
	}

	async search(request, signal) {
		const options = this.resolveOptions();
		const apiKey = await this.apiKey(options, signal);
		throwIfAborted(signal);
		const endpoint = `${options.baseURL.replace(/\/$/u, "")}/v2/search`;
		const body = {
			query: request.query,
			limit: request.maxResults ?? options.maxResults,
			sources: ["web"]
		};
		options.recordRequest?.({
			endpoint,
			body
		});
		throwIfAborted(signal);
		const effect = new AbortController();
		let timedOut = false;
		const onTimeout = () => {
			timedOut = true;
			effect.abort(new Error("Firecrawl search timed out"));
		};
		const timer = setTimeout(onTimeout, options.timeoutMs);
		const onAbort = () => effect.abort(signal?.reason);
		signal?.addEventListener("abort", onAbort, { once: true });
		let response;
		try {
			response = await fetch(endpoint, {
				method: "POST",
				redirect: "error",
				headers: {
					"authorization": `Bearer ${apiKey}`,
					"content-type": "application/json",
					"accept": "application/json",
					"user-agent": USER_AGENT
				},
				body: JSON.stringify(body),
				signal: effect.signal
			});
		} catch (error) {
			if (timedOut) throw new WebError("Firecrawl search timed out", "WEB_PROVIDER_ERROR", { cause: error });
			if (signal?.aborted === true || isAbortError(error)) throw webAborted(signal, error);
			throw new WebError(`Firecrawl search request failed: ${String(error)}`, "WEB_PROVIDER_ERROR", { cause: error });
		} finally {
			clearTimeout(timer);
			signal?.removeEventListener("abort", onAbort);
		}
		if (!response.ok) {
			let message = `Firecrawl API error (HTTP ${response.status})`;
			try {
				const parsed = await response.json();
				if (typeof parsed?.error === "string" && parsed.error.length > 0) message = parsed.error;
			} catch (_unparseable) {}
			throw new WebError(message, "WEB_PROVIDER_ERROR");
		}
		try {
			const parsed = await response.json();
			return mapFirecrawlResponse(parsed?.data ?? parsed);
		} catch (error) {
			if (signal?.aborted === true || isAbortError(error)) throw webAborted(signal, error);
			if (error instanceof WebError) throw error;
			throw new WebError(`Firecrawl returned an unprocessable response body: ${String(error)}`, "WEB_PROVIDER_ERROR", { cause: error });
		}
	}

	/**
	 * Resolve one operation's credential without retaining it on the provider.
	 * @param options - the caller's snapshot.
	 * @param signal - abort signal for the surrounding search.
	 * @returns the resolved key.
	 */
	async apiKey(options, signal) {
		return resolveApiKey(options, signal, "search");
	}
}

/** The Firecrawl-backed fetch provider; HTTP redirects fail as `WEB_PROVIDER_ERROR`. */
class FirecrawlFetchProvider {
	resolveOptions;
	id = FIRECRAWL_PROVIDER_ID;

	/**
	 * @param resolveOptions - the options for the NEXT operation, snapshotted
	 * once at each operation's entry so one fetch never mixes two sections.
	 */
	constructor(resolveOptions) {
		this.resolveOptions = resolveOptions;
	}

	available() {
		const options = this.resolveOptions();
		return ((options.apiKey?.length ?? 0) > 0 || options.resolveApiKey !== void 0) && URL.canParse(options.baseURL);
	}

	async fetch(request, signal) {
		const options = this.resolveOptions();
		const apiKey = await this.apiKey(options, signal);
		throwIfAborted(signal);
		const endpoint = `${options.baseURL.replace(/\/$/u, "")}/v2/scrape`;
		const body = {
			url: request.url,
			formats: FIRECRAWL_FETCH_FORMATS,
			onlyMainContent: true
		};
		options.recordRequest?.({
			endpoint,
			body
		});
		throwIfAborted(signal);
		const effect = new AbortController();
		let timedOut = false;
		const onTimeout = () => {
			timedOut = true;
			effect.abort(new Error("Firecrawl scrape timed out"));
		};
		const timer = setTimeout(onTimeout, options.timeoutMs);
		const onAbort = () => effect.abort(signal?.reason);
		signal?.addEventListener("abort", onAbort, { once: true });
		let response;
		try {
			response = await fetch(endpoint, {
				method: "POST",
				redirect: "error",
				headers: {
					"authorization": `Bearer ${apiKey}`,
					"content-type": "application/json",
					"accept": "application/json",
					"user-agent": USER_AGENT
				},
				body: JSON.stringify(body),
				signal: effect.signal
			});
		} catch (error) {
			if (timedOut) throw new WebError("Firecrawl scrape timed out", "WEB_PROVIDER_ERROR", { cause: error });
			if (signal?.aborted === true || isAbortError(error)) throw webAborted(signal, error);
			throw new WebError(`Firecrawl scrape request failed: ${String(error)}`, "WEB_PROVIDER_ERROR", { cause: error });
		} finally {
			clearTimeout(timer);
			signal?.removeEventListener("abort", onAbort);
		}
		if (!response.ok) {
			let message = `Firecrawl API error (HTTP ${response.status})`;
			try {
				const parsed = await response.json();
				if (typeof parsed?.error === "string" && parsed.error.length > 0) message = parsed.error;
			} catch (_unparseable) {}
			throw new WebError(message, "WEB_PROVIDER_ERROR");
		}
		try {
			const parsed = await response.json();
			return mapFirecrawlScrapeResponse(parsed?.data ?? parsed, request.url);
		} catch (error) {
			if (signal?.aborted === true || isAbortError(error)) throw webAborted(signal, error);
			if (error instanceof WebError) throw error;
			throw new WebError(`Firecrawl returned an unprocessable response body: ${String(error)}`, "WEB_PROVIDER_ERROR", { cause: error });
		}
	}

	/**
	 * Resolve one operation's credential without retaining it on the provider.
	 * @param options - the caller's snapshot.
	 * @param signal - abort signal for the surrounding fetch.
	 * @returns the resolved key.
	 */
	async apiKey(options, signal) {
		return resolveApiKey(options, signal, "fetch");
	}
}

/**
 * Project one resolved section into the options the provider serves its next
 * search with. Environment fallbacks stay here rather than in the provider:
 * every value it reads is already fully defaulted.
 * @param ctx - plugin context supplying the credential and environment planes.
 * @param config - the currently authoritative section.
 * @param kind - capability this option bundle serves ("search" or "fetch");
 *   selects the session-attributed request record key.
 * @returns options for one operation.
 */
function resolveOptions(ctx, config, kind = "search") {
	const apiKeyEnv = credentialRef(config.apiKeyEnv ?? DEFAULT_API_KEY_ENV);
	const literalApiKey = config.apiKey !== void 0 && config.apiKey.length > 0 ? config.apiKey : void 0;
	return {
		...(literalApiKey === void 0 ? {} : { apiKey: literalApiKey }),
		resolveApiKey: async () => {
			const credentials = ctx.get("credentials");
			if (credentials !== void 0) return (await credentials.resolve(apiKeyEnv))?.value;
			const ambient = launchEnvironmentOf(ctx).get(apiKeyEnv);
			return ambient !== void 0 && ambient.value.length > 0 ? ambient.value : void 0;
		},
		apiKeyEnv,
		baseURL: config.baseURL ?? launchEnvironmentOf(ctx).get(SEARCH_BASE_URL_ENV)?.value ?? FIRECRAWL_DEFAULT_BASE_URL,
		maxResults: config.maxResults ?? FIRECRAWL_DEFAULT_MAX_RESULTS,
		timeoutMs: config.timeoutMs ?? FIRECRAWL_DEFAULT_TIMEOUT_MS,
		// Do NOT append custom event types (e.g. `web/firecrawl-search-request`)
		// to the session log: this harness build (0.1.1-rc.2) refuses to re-read
		// logs containing event types outside its built-in vocabulary unless the
		// envelope carries `ignorable: true` — and `Session.append` in this build
		// cannot set that marker (plugin event-type registration is deferred
		// upstream). Writing such events makes the whole session unloadable
		// ("history unavailable ... SessionFormatUnsupportedError").
		recordRequest: void 0
	};
}

/** Register the Firecrawl search and fetch providers with `ctx.web`. */
function apply(ctx, config) {
	let current = () => config;
	installSettingsSection(ctx, WEB_SEARCH_FIRECRAWL_SETTINGS_NAMESPACE, Config, config, {
		setSource: (source) => {
			current = source;
		},
		onChange: () => {}
	});
	ctx.web.registerSearchProvider(new FirecrawlSearchProvider(() => resolveOptions(ctx, current(), "search")));
	ctx.web.registerFetchProvider(new FirecrawlFetchProvider(() => resolveOptions(ctx, current(), "fetch")));
}

/** Race a same-process asynchronous preflight against caller cancellation. */
function abortable(operation, signal) {
	if (signal === void 0) return operation;
	if (signal.aborted) return Promise.reject(webAborted(signal));
	return new Promise((resolve, reject) => {
		const onAbort = () => {
			reject(webAborted(signal));
		};
		signal.addEventListener("abort", onAbort, { once: true });
		operation.then((value) => {
			signal.removeEventListener("abort", onAbort);
			resolve(value);
		}, (error) => {
			signal.removeEventListener("abort", onAbort);
			reject(new Error(String(error).replace(/^Error: /u, ""), { cause: error }));
		});
	});
}

/** Throw the provider's stable cancellation error when the caller already aborted. */
function throwIfAborted(signal) {
	if (signal?.aborted === true) throw webAborted(signal);
}

/** Build the provider's stable cancellation error while retaining the caller's reason. */
function webAborted(signal, fallback) {
	return new WebError("Firecrawl web operation aborted", "WEB_ABORTED", { cause: signal?.aborted === true ? signal.reason : fallback });
}

/**
 * Resolve one operation's credential without retaining it on the provider.
 * Shared by the search and fetch providers; the error text is scoped by `kind`
 * so a missing or failing key names the capability that actually ran.
 * @param options - the caller's snapshot.
 * @param signal - abort signal for the surrounding operation.
 * @param kind - capability label used in error text ("search" or "fetch").
 * @returns the resolved key.
 */
async function resolveApiKey(options, signal, kind) {
	throwIfAborted(signal);
	if (options.apiKey !== void 0 && options.apiKey.length > 0) return options.apiKey;
	let resolved;
	try {
		resolved = await abortable(options.resolveApiKey?.() ?? Promise.resolve(void 0), signal);
	} catch (error) {
		if (signal?.aborted === true || isAbortError(error)) throw webAborted(signal, error);
		throw new WebError(`Firecrawl ${kind} credential resolution failed: ${String(error)}`, "WEB_PROVIDER_ERROR", { cause: error });
	}
	if (resolved !== void 0 && resolved.length > 0) return resolved;
	throw new WebError(`Firecrawl ${kind} has no API key for "${options.apiKeyEnv ?? "FIRECRAWL_API_KEY"}"; store it through the credentials service, export it in the launching environment, or set a literal "apiKey" in the web-search-firecrawl config`, "WEB_PROVIDER_CREDENTIAL_MISSING");
}

/** True for a fetch/`AbortSignal` abort, surfaced as `WEB_ABORTED`. */
function isAbortError(error) {
	return error instanceof DOMException && error.name === "AbortError";
}

/** True for a positive integer (used for the result cap and timeout). */
function isPositiveInteger(value) {
	return Number.isInteger(value) && value > 0;
}

export {
	Config,
	FIRECRAWL_DEFAULT_BASE_URL,
	FIRECRAWL_DEFAULT_MAX_RESULTS,
	FIRECRAWL_DEFAULT_TIMEOUT_MS,
	FIRECRAWL_FETCH_FORMATS,
	FIRECRAWL_PROVIDER_ID,
	FirecrawlFetchProvider,
	FirecrawlSearchProvider,
	WEB_SEARCH_FIRECRAWL_SETTINGS_NAMESPACE,
	apply,
	inject,
	mapFirecrawlResponse,
	mapFirecrawlScrapeResponse,
	name
};
