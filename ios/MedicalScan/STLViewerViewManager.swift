import Foundation

@objc(STLViewerViewManager)
class STLViewerViewManager: RCTViewManager {
  override func view() -> UIView! {
    return STLViewerView()
  }

  override static func requiresMainQueueSetup() -> Bool {
    return true
  }
}