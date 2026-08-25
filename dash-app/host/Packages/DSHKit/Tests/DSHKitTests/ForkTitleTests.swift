import XCTest
@testable import DSHKit

/// 分叉标题的序号递增规则。与上游 `increasedForkTitle`（dsh-client-runtime）
/// 逐条对齐：两个界面分叉出来的会话必须叫同一个名字，否则同一份数据在
/// web 与原生里读起来像两回事。
final class ForkTitleTests: XCTestCase {

    func testUnnumberedTitleStartsAtOne() {
        XCTAssertEqual(SessionStore.increasedForkTitle("重构侧边栏"), "重构侧边栏 (1)")
    }

    func testHalfWidthNumberIncrements() {
        XCTAssertEqual(SessionStore.increasedForkTitle("重构侧边栏 (1)"), "重构侧边栏 (2)")
        XCTAssertEqual(SessionStore.increasedForkTitle("x(9)"), "x(10)")
    }

    func testFullWidthParenthesesArePreserved() {
        XCTAssertEqual(SessionStore.increasedForkTitle("重构侧边栏（2）"), "重构侧边栏（3）")
    }

    /// 上游正则里的 `\d` 只认 ASCII 数字：全角数字不是序号，整串当作没编号。
    func testFullWidthDigitsAreNotANumber() {
        XCTAssertEqual(SessionStore.increasedForkTitle("x(１)"), "x(１) (1)")
    }

    /// 括号里不是纯数字 → 不是序号。
    func testNonNumericParenthesesFallBack() {
        XCTAssertEqual(SessionStore.increasedForkTitle("修 bug (紧急)"), "修 bug (紧急) (1)")
        XCTAssertEqual(SessionStore.increasedForkTitle("空括号()"), "空括号() (1)")
    }

    /// 只认最后一对括号（上游的非贪婪前缀等价物）。
    func testOnlyTheTrailingNumberCounts() {
        XCTAssertEqual(SessionStore.increasedForkTitle("(3) 计划 (7)"), "(3) 计划 (8)")
    }
}
