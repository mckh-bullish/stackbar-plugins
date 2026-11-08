import Foundation
import XCTest
import StackbarHostCore
import StackbarProtocol
@testable import Plugin_OpenRouter

/// OpenRouter's host is fixed, so the replies are parsed directly; the
/// running plugin is checked without a key, where it contacts nothing.
final class OpenRouterTests: XCTestCase {
    @MainActor func testTheBudgetThatStopsTheKeyFirstIsTheLimit() async throws {
        let body = #"""
        {"data": {"label": "sk-or-v1-au7...890", "limit": 100, "limit_remaining": 74.5, "limit_reset": "monthly",
          "usage": 25.5, "usage_daily": 1.25, "usage_weekly": 6.5, "usage_monthly": 25.5, "is_free_tier": false,
          "effective_budget": {"scope": "member", "limit_usd": 50, "spend_usd": 32.5, "remaining_usd": 17.5,
            "reset_interval": "weekly", "resets_at": "2026-10-12T00:00:00.000Z"},
          "free_model_daily_requests": {"used": 12, "limit": 50, "remaining": 38}}}
        """#
        let key = try OpenRouter.parseKey(Data(body.utf8))
        XCTAssertEqual(key.today, 1.25)
        XCTAssertEqual(key.week, 6.5)
        XCTAssertEqual(key.month, 25.5)
        XCTAssertEqual(key.limit?.max, 50)
        XCTAssertEqual(key.limit?.spend, 32.5)
        XCTAssertEqual(key.limit?.interval, "weekly")
        XCTAssertNotNil(key.limit?.resetsAt)
        XCTAssertEqual(key.freeRequests, OpenRouter.FreeRequests(used: 12, limit: 50))
    }

    @MainActor func testWithoutABudgetTheKeysOwnLimitCountsAndNoLimitIsNone() async throws {
        let limited = try OpenRouter.parseKey(Data(#"{"data": {"limit": 20, "limit_remaining": 15, "limit_reset": "daily", "usage": 90, "usage_daily": 5}}"#.utf8))
        XCTAssertEqual(limited.limit, OpenRouter.Limit(spend: 5, max: 20, resetsAt: nil, interval: "daily"))
        let open = try OpenRouter.parseKey(Data(#"{"data": {"limit": null, "usage": 3, "usage_daily": 0, "effective_budget": null}}"#.utf8))
        XCTAssertNil(open.limit)
        XCTAssertEqual(open.label, "API key")
    }

    @MainActor func testActivityIsSummedByDayAndByModel() async throws {
        let body = #"""
        {"data": [
          {"date": "2026-11-06", "model": "openai/gpt-5-mini", "model_permaslug": "x", "endpoint_id": "a", "provider_name": "OpenAI",
           "usage": 0.5, "byok_usage_inference": 0, "requests": 10, "prompt_tokens": 1000, "completion_tokens": 200, "reasoning_tokens": 0, "cached_tokens": 0},
          {"date": "2026-11-06", "model": "openai/gpt-5-mini", "model_permaslug": "x", "endpoint_id": "b", "provider_name": "Azure",
           "usage": 0.25, "byok_usage_inference": 0, "requests": 5, "prompt_tokens": 500, "completion_tokens": 100, "reasoning_tokens": 0, "cached_tokens": 0},
          {"date": "2026-11-07", "model": "anthropic/claude-sonnet-4.5", "model_permaslug": "y", "endpoint_id": "c", "provider_name": "Anthropic",
           "usage": 2, "byok_usage_inference": 0, "requests": 4, "prompt_tokens": 3000, "completion_tokens": 400, "reasoning_tokens": 0, "cached_tokens": 0}
        ]}
        """#
        let (days, models) = try OpenRouter.parseActivity(Data(body.utf8))
        XCTAssertEqual(days["2026-11-06"], OpenRouter.Day(spend: 0.75, tokens: 1800, requests: 15))
        XCTAssertEqual(days["2026-11-07"], OpenRouter.Day(spend: 2, tokens: 3400, requests: 4))
        XCTAssertEqual(models.map(\.name), ["anthropic/claude-sonnet-4.5", "openai/gpt-5-mini"], "most spend first")
        XCTAssertEqual(models.last?.requests, 15)
    }

    @MainActor func testDaysAreUTCDays() async {
        XCTAssertEqual(OpenRouter.day(of: Date(timeIntervalSince1970: 1_793_923_200 - 1)), "2026-11-05")
        XCTAssertEqual(OpenRouter.day(of: Date(timeIntervalSince1970: 1_793_923_200)), "2026-11-06")
    }

    @MainActor func testALimitWithoutAResetDateIsAnnouncedOncePerPeriod() async {
        let thursday = Date(timeIntervalSince1970: 1_793_923_200 - 86400) // 2026-11-05
        let sunday = Date(timeIntervalSince1970: 1_793_923_200 + 2 * 86400) // 2026-11-08
        let monday = Date(timeIntervalSince1970: 1_793_923_200 + 3 * 86400) // 2026-11-09
        let monthly = OpenRouter.Limit(spend: 95, max: 100, resetsAt: nil, interval: "monthly")
        XCTAssertEqual(OpenRouter.window(monthly, now: thursday), "monthly|2026-11")
        let weekly = OpenRouter.Limit(spend: 95, max: 100, resetsAt: nil, interval: "weekly")
        XCTAssertEqual(OpenRouter.window(weekly, now: thursday), OpenRouter.window(weekly, now: sunday))
        XCTAssertNotEqual(OpenRouter.window(weekly, now: sunday), OpenRouter.window(weekly, now: monday))
        XCTAssertEqual(OpenRouter.window(OpenRouter.Limit(spend: 1, max: 2, resetsAt: nil, interval: nil), now: monday), "lifetime")
    }

    func testWithoutAKeyItAsksForOneAndContactsNothing() async throws {
        let host = Host(self)
        let supervisor = try await host.start("OpenRouter")
        let panel = await supervisor.views[.panel].map { TreeTextRenderer.render($0) } ?? ""
        XCTAssertTrue(panel.contains("OPENROUTER_API_KEY"), panel)
        let summary = await supervisor.callTool("usage_summary").text
        XCTAssertTrue(summary.contains("not connected"), summary)
        await supervisor.stop()
    }
}
