#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <notify.h>

static const char *kCPWWeatherNotify = "com.sushibta.vmlspeedbubble.weather";
static int gCPWToken = 0;
static UIWindow *gCPWWindow = nil;
static UILabel *gCPWLabel = nil;
static AVSpeechSynthesizer *gCPWSpeech = nil;

static BOOL CPWIsCarPlayApp(void) { return [NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.CarPlayApp"]; }
static BOOL CPWSceneLooksCarPlay(UIWindowScene *scene) { if (!scene) return NO; NSString *role=scene.session.role?:@""; if ([role localizedCaseInsensitiveContainsString:@"CarPlay"]) return YES; CGSize s=scene.screen.bounds.size; return s.width>s.height && s.width>=300 && s.height<=500; }
static UIWindowScene *CPWFindScene(void) { UIWindowScene *best=nil; CGFloat score=-CGFLOAT_MAX; for(UIScene *raw in UIApplication.sharedApplication.connectedScenes){ if(![raw isKindOfClass:UIWindowScene.class])continue; UIWindowScene *scene=(UIWindowScene *)raw; if(!CPWSceneLooksCarPlay(scene))continue; CGSize s=scene.screen.bounds.size; CGFloat x=s.width*s.height; if(!best||x>score){best=scene;score=x;}} return best; }

static void CPWEnsureWindow(void) {
    if(!CPWIsCarPlayApp())return; UIWindowScene *scene=CPWFindScene(); if(!scene)return;
    if(gCPWWindow&&gCPWWindow.windowScene!=scene){gCPWWindow.hidden=YES;gCPWWindow.rootViewController=nil;gCPWWindow=nil;gCPWLabel=nil;}
    CGRect bounds=scene.coordinateSpace.bounds; if(CGRectIsEmpty(bounds))bounds=scene.screen.bounds;
    if(!gCPWWindow){
        gCPWWindow=[[UIWindow alloc]initWithWindowScene:scene]; gCPWWindow.backgroundColor=UIColor.clearColor; gCPWWindow.userInteractionEnabled=NO;
        UIViewController *vc=[UIViewController new]; vc.view.backgroundColor=UIColor.clearColor; vc.view.userInteractionEnabled=NO; gCPWWindow.rootViewController=vc;
        UILabel *label=[UILabel new]; label.numberOfLines=2; label.textAlignment=NSTextAlignmentLeft; label.textColor=UIColor.whiteColor; label.backgroundColor=[UIColor colorWithWhite:0.055 alpha:0.94]; label.layer.cornerRadius=14; label.layer.masksToBounds=YES; label.layer.borderWidth=.5; label.layer.borderColor=[UIColor colorWithWhite:1 alpha:.16].CGColor; label.hidden=YES; label.userInteractionEnabled=NO; [vc.view addSubview:label]; gCPWLabel=label;
    }
    gCPWWindow.frame=bounds; gCPWWindow.rootViewController.view.frame=bounds; CGFloat width=MIN(bounds.size.width-36,580); gCPWLabel.frame=CGRectMake((bounds.size.width-width)/2,MAX(12,bounds.size.height*.045),width,72);
    CGFloat highest=UIWindowLevelAlert; for(UIWindow *w in scene.windows)if(w&&w!=gCPWWindow)highest=MAX(highest,w.windowLevel); gCPWWindow.windowLevel=MAX(UIWindowLevelAlert+250,highest+120); gCPWWindow.hidden=NO; gCPWWindow.alpha=1;
}

static NSString *CPWDescription(NSInteger code){ if(code==0)return @"Trời quang"; if(code<=3)return @"Có mây"; if(code==45||code==48)return @"Sương mù"; if((code>=51&&code<=57)||(code>=61&&code<=67)||(code>=80&&code<=82))return @"Có mưa"; if(code>=71&&code<=77)return @"Có tuyết"; if(code>=95)return @"Có dông"; return @"Thời tiết thay đổi"; }

static NSAttributedString *CPWBannerText(double tempC,NSString *condition,double wind){
    NSString *line1=[NSString stringWithFormat:@"   %.0f°C   %@",tempC,condition]; NSString *line2=[NSString stringWithFormat:@"   Điểm đến  •  Gió %.0f km/h",wind]; NSString *all=[NSString stringWithFormat:@"%@\n%@",line1,line2]; NSMutableParagraphStyle *style=[NSMutableParagraphStyle new]; style.lineSpacing=1; style.alignment=NSTextAlignmentLeft;
    NSMutableAttributedString *a=[[NSMutableAttributedString alloc]initWithString:all attributes:@{NSForegroundColorAttributeName:UIColor.whiteColor,NSFontAttributeName:[UIFont systemFontOfSize:17 weight:UIFontWeightRegular],NSParagraphStyleAttributeName:style}];
    NSRange r=[line1 rangeOfString:[NSString stringWithFormat:@"%.0f°C",tempC]]; if(r.location!=NSNotFound)[a addAttribute:NSFontAttributeName value:[UIFont systemFontOfSize:25 weight:UIFontWeightSemibold] range:r]; r=[line1 rangeOfString:condition]; if(r.location!=NSNotFound)[a addAttribute:NSFontAttributeName value:[UIFont systemFontOfSize:19 weight:UIFontWeightSemibold] range:r]; NSRange second=NSMakeRange(line1.length+1,line2.length); [a addAttribute:NSForegroundColorAttributeName value:[UIColor colorWithWhite:.86 alpha:1] range:second]; [a addAttribute:NSFontAttributeName value:[UIFont systemFontOfSize:16 weight:UIFontWeightRegular] range:second]; return a;
}

static void CPWSpeak(double tempC,NSString *condition,double wind){
    dispatch_async(dispatch_get_main_queue(), ^{
        NSError *audioError=nil; AVAudioSession *session=AVAudioSession.sharedInstance;
        [session setCategory:AVAudioSessionCategoryPlayback mode:AVAudioSessionModeSpokenAudio options:AVAudioSessionCategoryOptionDuckOthers error:&audioError];
        if(audioError)NSLog(@"[CPWVOICE] category error=%@",audioError);
        audioError=nil; [session setActive:YES withOptions:0 error:&audioError]; if(audioError)NSLog(@"[CPWVOICE] active error=%@",audioError);
        if(!gCPWSpeech)gCPWSpeech=[AVSpeechSynthesizer new]; [gCPWSpeech stopSpeakingAtBoundary:AVSpeechBoundaryImmediate];
        NSString *speech=[NSString stringWithFormat:@"Thời tiết tại điểm đến. %.0f độ, %@, gió %.0f ki lô mét một giờ.",tempC,condition.lowercaseString,wind];
        AVSpeechUtterance *u=[AVSpeechUtterance speechUtteranceWithString:speech]; AVSpeechSynthesisVoice *voice=[AVSpeechSynthesisVoice voiceWithLanguage:@"vi-VN"]; if(voice)u.voice=voice; u.rate=.46; u.pitchMultiplier=1; u.volume=1; u.preUtteranceDelay=.2; NSLog(@"[CPWVOICE] speak=%@ voice=%@",speech,voice.language); [gCPWSpeech speakUtterance:u];
    });
}

static void CPWShowWeather(double tempC,NSString *condition,double wind,NSTimeInterval duration){ dispatch_async(dispatch_get_main_queue(), ^{ CPWEnsureWindow(); if(!gCPWWindow||!gCPWLabel)return; gCPWLabel.attributedText=CPWBannerText(tempC,condition,wind); gCPWLabel.hidden=NO; gCPWLabel.alpha=0; gCPWLabel.transform=CGAffineTransformMakeTranslation(0,-8); [UIView animateWithDuration:.22 animations:^{gCPWLabel.alpha=1;gCPWLabel.transform=CGAffineTransformIdentity;}]; CPWSpeak(tempC,condition,wind); dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(duration*NSEC_PER_SEC)),dispatch_get_main_queue(),^{[UIView animateWithDuration:.22 animations:^{gCPWLabel.alpha=0;gCPWLabel.transform=CGAffineTransformMakeTranslation(0,-6);} completion:^(__unused BOOL f){gCPWLabel.hidden=YES;gCPWLabel.transform=CGAffineTransformIdentity;}];}); }); }
static void CPWReadWeather(int token){uint64_t state=0;if(notify_get_state(token,&state)!=NOTIFY_STATUS_OK)return;NSInteger tp=(NSInteger)(state&0xFFFFULL),code=(NSInteger)((state>>16)&0xFFULL),wp=(NSInteger)((state>>24)&0xFFFFULL);double t=((double)tp-1000)/10.0,w=((double)wp)/10.0;CPWShowWeather(t,CPWDescription(code),w,8);}
static void CPWStartReceiver(void){if(!CPWIsCarPlayApp()||gCPWToken)return;int token=0;uint32_t s=notify_register_dispatch(kCPWWeatherNotify,&token,dispatch_get_main_queue(),^(int incoming){gCPWToken=incoming;CPWReadWeather(incoming);});if(s==NOTIFY_STATUS_OK)gCPWToken=token;}
%ctor {@autoreleasepool{if(!CPWIsCarPlayApp())return;CPWStartReceiver();[[NSNotificationCenter defaultCenter]addObserverForName:UISceneDidActivateNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(__unused NSNotification *n){dispatch_after(dispatch_time(DISPATCH_TIME_NOW,600*NSEC_PER_MSEC),dispatch_get_main_queue(),^{CPWEnsureWindow();});}];}}
