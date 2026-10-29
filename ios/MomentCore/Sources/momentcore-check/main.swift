import Foundation
import MomentCoreScenarios

let failures = await Scenarios.runAll()
exit(failures == 0 ? 0 : 1)
