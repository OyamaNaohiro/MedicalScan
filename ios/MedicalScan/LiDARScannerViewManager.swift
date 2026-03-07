import Foundation
import UIKit

@objc(LiDARScannerViewManager)
class LiDARScannerViewManager: RCTViewManager {

  override func view() -> UIView! {
    return LiDARScannerView()
  }

  override static func requiresMainQueueSetup() -> Bool {
    return true
  }
}
