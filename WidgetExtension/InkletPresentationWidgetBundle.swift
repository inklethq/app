import InkletPresentationWidget
import SwiftUI
import WidgetKit

@main
struct InkletPresentationWidgetBundle: WidgetBundle {
    var body: some Widget {
        QuickSendWidget()
        ActivityWidget()
        InkletPresentationWidget()
        InkletExtraLargePresentationWidget()
    }
}
