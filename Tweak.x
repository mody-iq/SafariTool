#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

// %ctor يعمل مرة واحدة عند تحميل الأداة داخل العملية المستهدفة.
// لا يوجد أي %hook أو ميزة وظيفية في هذه المرحلة — فقط تأكيد التحميل.
%ctor {
    NSLog(@"[SafariTool] Tweak loaded successfully. RootHide / iOS 18.7 ready.");
}
