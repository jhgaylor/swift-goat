import Testing
import FountainKit
@testable import GoatCore

@Suite struct DescribeErrorTests {
    @Test func mapsKnownCodesToCopy() {
        let error = FountainError.api(
            APIErrorBody(code: "runner_offline", message: nil), status: 503
        )
        #expect(describe(error) == "The runner this teammate lives on is offline.")
    }

    @Test func fallsBackToErrorDescription() {
        let error = FountainError.missingAPIKey
        #expect(describe(error) == "No Fountain API key. Add one in Settings.")
    }
}
