/*
 * dsh-web-search-firecrawl — browser half (lazy-CJS classic script, hand-written, no build step).
 *
 * Registers a settings card into the Plugins > "Plugin configuration" tab, keyed by the
 * `web-search-firecrawl` settings namespace the Host plugin exposes. The card edits:
 *   - apiKey  (write-only, through the credentials domain; shows a "configured" badge)
 *   - baseURL (endpoint)
 *   - maxResults (max results per request)
 *
 * It deliberately does NOT depend on the card components that are internal to
 * @deepseek-ai/dsh-client-ui-settings-plugins (PluginCard/ValueField/SecretField/CardForm are
 * not exported by any runtime module). Instead it renders plain inputs styled with the same
 * --dsw-alias-* theme variables, and owns a small staged-form model (CardModel) that writes a
 * duration-fenced settings document on save — one save covers the section writes and the
 * credential write, exactly like the DeepSeek WebSearchCard.
 */
window.__ModuleLoader__.load({
	id: "dsh-web-search-firecrawl",
	factory: (require) => {
		var module = { exports: {} };
		var exports = module.exports;
		Object.defineProperty(exports, Symbol.toStringTag, { value: "Module" });

		let react_jsx_runtime = require("react/jsx-runtime");
		let react = require("react");
		let runtime_client = require("@deepseek-ai/dsh-client-runtime/client");

		const jsx = react_jsx_runtime.jsx;
		const jsxs = react_jsx_runtime.jsxs;
		const Fragment = react_jsx_runtime.Fragment;
		const createSnapshotStore = runtime_client.createSnapshotStore;

		// ---- config + locale ----
		const FIRECRAWL_NS = "web-search-firecrawl";
		const DEFAULT_API_KEY_REF = "FIRECRAWL_API_KEY";
		const API_KEY_FIELD = "apiKey";
		const NS = "settings.plugins.firecrawl";

		const en = {
			title: "Web search",
			description: "The Firecrawl search provider.",
			apiKey: "API key",
			apiKeyHint: "Stored outside the settings file. Leave blank to keep the current key.",
			apiKeySet: "A key is configured.",
			apiKeyUnset: "No key is configured; search is unavailable until one is.",
			baseUrl: "Endpoint",
			baseUrlHint: "Leave blank to use the provider default.",
			maxResults: "Max results per request",
			maxResultsHint: "How many results one search may return.",
			save: "Save",
			saving: "Saving…",
			discard: "Discard",
			unsaved: "Unsaved",
			invalidNumber: "Enter a number, or leave blank to use the default.",
			reset: "Reset to default",
			overridden: "Overridden"
		};
		const zh = {
			title: "网页搜索",
			description: "Firecrawl 搜索提供方。",
			apiKey: "API Key",
			apiKeyHint: "不写入设置文件。留空表示保持当前密钥。",
			apiKeySet: "已配置密钥。",
			apiKeyUnset: "未配置密钥；配置之前搜索不可用。",
			baseUrl: "接口地址",
			baseUrlHint: "留空则使用提供方默认地址。",
			maxResults: "单次请求最多结果数",
			maxResultsHint: "一次搜索最多返回多少条结果。",
			save: "保存",
			saving: "保存中…",
			discard: "放弃修改",
			unsaved: "未保存",
			invalidNumber: "请填数字；留空表示使用默认值。",
			reset: "恢复默认",
			overridden: "已覆盖"
		};

		// ---- CSS (injected at load, tagged so the module system claims it) ----
		const STYLE_ID = "dsh-web-search-firecrawl";
		if (typeof document !== "undefined" && document.querySelector("style[data-plugin-css=" + JSON.stringify(STYLE_ID) + "]") === null) {
			const tag = document.createElement("style");
			tag.dataset.plugin = "dsh-web-search-firecrawl";
			tag.dataset.pluginCss = STYLE_ID;
			tag.textContent = [
				".fcs_card{display:flex;flex-direction:column;gap:4px}",
				".fcs_head h3{margin:0;font-size:14px;font-weight:600;color:var(--dsw-alias-label-primary)}",
				".fcs_desc{margin:0;color:var(--dsw-alias-label-tertiary);font-size:12px}",
				".fcs_field{display:flex;flex-direction:column;gap:6px;padding:12px 0}",
				".fcs_field+.fcs_field{border-top:1px solid var(--dsw-alias-border-l2)}",
				".fcs_label{color:var(--dsw-alias-label-primary);font-size:13px;font-weight:500}",
				".fcs_input{border:1px solid var(--dsw-alias-border-l2);background:var(--dsw-alias-bg-layer-3);height:34px;font:inherit;color:var(--dsw-alias-label-primary);border-radius:8px;padding:0 12px;font-size:13px}",
				".fcs_input:focus-visible{border-color:var(--dsw-alias-brand-primary);outline:none}",
				".fcs_input:disabled{color:var(--dsw-alias-label-tertiary);cursor:default}",
				".fcs_hint{color:var(--dsw-alias-label-tertiary);margin:0;font-size:12px}",
				".fcs_badge{align-self:flex-start;white-space:nowrap;background:var(--dsw-alias-bg-module-platform);color:var(--dsw-alias-label-secondary);border-radius:999px;padding:1px 8px;font-size:11px;font-weight:500;line-height:17px}",
				".fcs_badgeMuted{color:var(--dsw-alias-label-tertiary)}",
				".fcs_badges{display:flex;align-items:center;gap:8px}",
				".fcs_meta{display:flex;align-items:center;justify-content:space-between;gap:8px}",
				".fcs_reset{font:inherit;color:var(--dsw-alias-label-secondary);cursor:pointer;background:0 0;border:none;padding:0;font-size:12px}",
				".fcs_reset:hover:not(:disabled){color:var(--dsw-alias-label-primary)}",
				".fcs_foot{display:flex;justify-content:flex-end;gap:8px;padding:8px 0 4px}",
				".fcs_btn{font:inherit;cursor:pointer;border-radius:8px;height:32px;padding:0 16px;font-size:13px;border:1px solid var(--dsw-alias-border-l2);background:var(--dsw-alias-bg-layer-3);color:var(--dsw-alias-label-primary)}",
				".fcs_btn:disabled{cursor:default;opacity:.5}",
				".fcs_btnPrimary{background:var(--dsw-alias-brand-primary);border-color:var(--dsw-alias-brand-primary);color:var(--dsw-alias-color-fixed-on-primary,#fff)}"
			].join("\n");
			document.head.appendChild(tag);
		}

		// ---- field specs ----
		function textField(field) {
			return {
				field,
				format: (value) => typeof value === "string" ? value : "",
				parse: (text) => {
					const trimmed = text.trim();
					return trimmed === "" ? { kind: "clear" } : { kind: "set", value: trimmed };
				}
			};
		}
		function numberField(field) {
			return {
				field,
				format: (value) => typeof value === "number" ? String(value) : "",
				parse: (text) => {
					const trimmed = text.trim();
					if (trimmed === "") return { kind: "clear" };
					const parsed = Number(trimmed);
					return Number.isFinite(parsed) ? { kind: "set", value: parsed } : void 0;
				}
			};
		}

		// ---- staged form model (bare-bones CardForm equivalent) ----
		var CardModel = class {
			constructor(scope, specs, secrets = []) {
				this.scope = scope;
				this.specs = new Map(specs.map((spec) => [spec.field, spec]));
				this.secretSpecs = new Map(secrets.map((spec) => [spec.field, spec]));
				this.staged = new Map();
				this.listeners = new Set();
				this.saving = false;
				this.failed = false;
				scope.subscribe(() => this.publish());
			}
			bind(project) {
				const store = createSnapshotStore(project());
				this.listeners.add(() => store.set(project()));
				return store;
			}
			publish() {
				for (const listener of this.listeners) listener();
			}
			shell() {
				const snapshot = this.scope.getSnapshot();
				const plan = this.plan();
				return {
					available: snapshot.status === "ready",
					writable: snapshot.writable,
					dirty: plan.length > 0,
					invalid: plan.some((item) => item.run === void 0),
					saving: this.saving,
					failed: this.failed
				};
			}
			field(field) {
				const staged = this.staged.get(field);
				if (this.secretSpecs.has(field)) return { text: staged?.text ?? "", overridden: false, invalid: false };
				const spec = this.spec(field);
				if (staged === void 0) return { text: spec.format(this.sectionValue(field)), overridden: this.stored(field), invalid: false };
				const write = staged.clear ? { kind: "clear" } : spec.parse(staged.text);
				return { text: staged.text, overridden: write?.kind === "set", invalid: write === void 0 };
			}
			actions() {
				return {
					edit: (field, text) => this.stage(field, { text, clear: false }),
					resetField: (field) => this.stage(field, { text: this.spec(field).format(this.baseValue(field)), clear: true }),
					save: () => this.save(),
					discard: () => {
						if (this.staged.size === 0 && !this.failed) return;
						this.staged.clear();
						this.failed = false;
						this.publish();
					}
				};
			}
			async save() {
				const plan = this.plan();
				const writes = plan.flatMap((item) => item.run === void 0 ? [] : [item.run]);
				if (plan.length === 0 || this.saving || writes.length !== plan.length) return;
				this.saving = true;
				this.failed = false;
				this.publish();
				let landed = true;
				for (const write of writes) landed = await write() && landed;
				if (landed) this.staged.clear();
				this.saving = false;
				this.failed = !landed;
				this.publish();
			}
			plan() {
				const plan = [];
				for (const [field, staged] of this.staged) {
					const secret = this.secretSpecs.get(field);
					if (secret !== void 0) {
						const value = staged.text.trim();
						if (value !== "") plan.push({ field, run: () => secret.write(value) });
						continue;
					}
					const spec = this.spec(field);
					if (staged.clear) {
						if (this.stored(field)) plan.push({ field, run: () => this.clear(field) });
						continue;
					}
					if (staged.text === spec.format(this.sectionValue(field))) continue;
					const write = spec.parse(staged.text);
					if (write === void 0) plan.push({ field, run: void 0 });
					else if (write.kind === "clear") plan.push({ field, run: () => this.clear(field) });
					else plan.push({ field, run: () => this.store(field, write.value) });
				}
				return plan;
			}
			async clear(field) {
				await this.scope.unset(field);
				return !this.stored(field);
			}
			async store(field, value) {
				await this.scope.set(field, value);
				return this.userLayer()?.[field] === value;
			}
			stage(field, edit) {
				this.staged.set(field, edit);
				this.failed = false;
				this.publish();
			}
			spec(field) {
				const spec = this.specs.get(field);
				if (spec === void 0) throw new Error(`firecrawl card has no field ${field}`);
				return spec;
			}
			snapshotOf() {
				return this.scope.getSnapshot();
			}
			sectionValue(field) {
				return this.snapshotOf().value?.[field];
			}
			baseValue(field) {
				return this.snapshotOf().base?.[field];
			}
			userLayer() {
				return this.snapshotOf().user;
			}
			stored(field) {
				const user = this.userLayer();
				return user !== void 0 && Object.hasOwn(user, field);
			}
		};

		// ---- controller ----
		var FirecrawlCardController = class {
			constructor(scope, api) {
				this.scope = scope;
				this.api = api;
				this.credential = { ref: "", configured: false, writable: true };
				this.form = new CardModel(scope, [textField("baseURL"), numberField("maxResults")], [{
					field: API_KEY_FIELD,
					write: (text) => this.writeKey(text)
				}]);
				this.store = this.form.bind(() => this.projection());
				scope.subscribe(() => this.readCredential());
				this.readCredential();
			}
			projection() {
				return {
					...this.form.shell(),
					baseURL: this.form.field("baseURL"),
					maxResults: this.form.field("maxResults"),
					apiKey: this.form.field(API_KEY_FIELD),
					apiKeyConfigured: this.credential.configured,
					apiKeyWritable: this.credential.writable
				};
			}
			async readCredential() {
				const ref = refOf(this.scope.getSnapshot());
				if (ref !== this.credential.ref) {
					this.credential = { ref, configured: false, writable: true };
					this.store.set(this.projection());
				}
				let response;
				try {
					response = await this.api.credentials.describe({ refs: [ref] });
				} catch (_credentialReadFailure) { return; }
				if (!response.result.ok || ref !== refOf(this.scope.getSnapshot())) return;
				const view = response.result.value.credentials[ref];
				const next = {
					ref,
					configured: view?.configured ?? false,
					writable: view?.writable ?? true
				};
				if (next.configured === this.credential.configured && next.writable === this.credential.writable) return;
				this.credential = next;
				this.store.set(this.projection());
			}
			refreshCredential(ref) {
				if (ref !== this.credential.ref) return;
				this.readCredential();
			}
			inject() {
				return { hooks: { firecrawlCard: this.store }, ...this.form.actions() };
			}
			async writeKey(value) {
				try {
					await this.api.credentials.set({ ref: refOf(this.scope.getSnapshot()), value });
				} catch (_credentialWriteFailure) {}
				await this.readCredential();
				return this.credential.configured;
			}
		};
		function refOf(snapshot) {
			const declared = snapshot.value?.apiKeyEnv;
			return declared !== void 0 && declared.length > 0 ? declared : DEFAULT_API_KEY_REF;
		}

		// ---- card component ----
		function FirecrawlCard(props) {
			const { t } = props;
			const state = props.useFirecrawlCard((snapshot) => snapshot);
			const disabled = !state.writable;
			return jsxs("section", {
				className: "fcs_card",
				children: [
					jsxs("header", {
						className: "fcs_head",
						children: [jsx("h3", { children: t("title") }), jsx("p", { className: "fcs_desc", children: t("description") })]
					}),
					jsxs("div", {
						className: "fcs_field",
						children: [
							jsxs("div", {
								className: "fcs_meta",
								children: [jsx("label", { className: "fcs_label", htmlFor: "fcs-firecrawl-key", children: t("apiKey") }), jsx("span", {
									className: "fcs_badge" + (state.apiKeyConfigured ? "" : " fcs_badgeMuted"),
									children: state.apiKeyConfigured ? t("apiKeySet") : t("apiKeyUnset")
								})]
							}),
							jsx("input", {
								id: "fcs-firecrawl-key",
								className: "fcs_input",
								type: "password",
								disabled: !state.apiKeyWritable,
								value: state.apiKey.text,
								placeholder: t("apiKeyHint"),
								onChange: (e) => props.edit("apiKey", e.target.value)
							}),
							jsx("p", { className: "fcs_hint", children: t("apiKeyHint") })
						]
					}),
					jsxs("div", {
						className: "fcs_field",
						children: [
							jsxs("div", {
								className: "fcs_meta",
								children: [jsx("label", { className: "fcs_label", htmlFor: "fcs-firecrawl-base", children: t("baseUrl") }), state.baseURL.overridden ? jsx("button", {
									className: "fcs_reset",
									onClick: () => props.resetField("baseURL"),
									children: t("reset")
								}) : null]
							}),
							jsx("input", {
								id: "fcs-firecrawl-base",
								className: "fcs_input",
								type: "text",
								disabled,
								value: state.baseURL.text,
								placeholder: t("baseUrlHint"),
								onChange: (e) => props.edit("baseURL", e.target.value)
							}),
							jsx("p", { className: "fcs_hint", children: t("baseUrlHint") })
						]
					}),
					jsxs("div", {
						className: "fcs_field",
						children: [
							jsxs("div", {
								className: "fcs_meta",
								children: [jsx("label", { className: "fcs_label", htmlFor: "fcs-firecrawl-max", children: t("maxResults") }), state.maxResults.overridden ? jsx("button", {
									className: "fcs_reset",
									onClick: () => props.resetField("maxResults"),
									children: t("reset")
								}) : null]
							}),
							jsx("input", {
								id: "fcs-firecrawl-max",
								className: "fcs_input",
								type: "number",
								disabled,
								value: state.maxResults.text,
								onChange: (e) => props.edit("maxResults", e.target.value)
							}),
							jsx("p", { className: "fcs_hint", children: t("maxResultsHint") })
						]
					}),
					jsxs("footer", {
						className: "fcs_foot",
						children: [jsx("button", {
							className: "fcs_btn",
							disabled: !state.dirty,
							onClick: () => props.discard(),
							children: t("discard")
						}), jsx("button", {
							className: "fcs_btn fcs_btnPrimary",
							disabled: disabled || !state.dirty || state.invalid || state.saving,
							onClick: () => props.save(),
							children: state.saving ? t("saving") : t("save")
						})]
					})
				]
			});
		}

		// ---- registration ----
		const inject = ["slots", "locale", "connection", "remote", "settingsScope"];
		function apply(ctx) {
			const { api } = ctx.get("connection");
			const t = ctx.locale.bind(NS);
			ctx.effect(() => ctx.locale.register(NS, { zh, en }), "web-search-firecrawl: section dictionaries");
			const firecrawl = new FirecrawlCardController(ctx.settingsScope.bind({ namespace: FIRECRAWL_NS }), api);
			ctx.effect(() => ctx.remote.$on("credentials/reference-updated", (ref) => {
				firecrawl.refreshCredential(ref);
			}), "web-search-firecrawl: credential invalidations");
			ctx.slots.inject("settings.plugin.item", function* () {
				yield ctx.slots.register({
					name: "settings.plugin.item",
					key: FIRECRAWL_NS,
					locale: NS,
					inject: () => firecrawl.inject()
				}, FirecrawlCard);
			});
		}

		exports.apply = apply;
		exports.inject = inject;
		return module.exports;
	}
});
