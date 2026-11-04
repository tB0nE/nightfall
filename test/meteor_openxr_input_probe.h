#pragma once
// Real loader/runtime action-state proof, independent of the game's bindings.
struct MeteorInputProbe {
    XrInstance instance;
    XrSession session;
    XrActionSet set=XR_NULL_HANDLE;
    XrAction actions[2]{};
    XrAction haptic=XR_NULL_HANDLE;
    XrPath hands[2]{};
    bool enabled=false;
    bool observing=false;
    int previous[2][2]={{-1,-1},{-1,-1}};
    MeteorInputProbe(XrInstance inst,XrSession sess):instance(inst),session(sess) {
        observing=std::getenv("METEOR_XR_OBSERVE_INPUT")!=nullptr;
        enabled=observing || std::getenv("METEOR_CONTROLLER_FIXTURE")!=nullptr;
        if(!enabled) return;
        check(xrStringToPath(instance,"/user/hand/left",hands),"left path");
        check(xrStringToPath(instance,"/user/hand/right",hands+1),"right path");
        XrActionSetCreateInfo si{XR_TYPE_ACTION_SET_CREATE_INFO};
        std::strcpy(si.actionSetName,"controller_proof"); std::strcpy(si.localizedActionSetName,"Controller proof");
        check(xrCreateActionSet(instance,&si,&set),"input action set");
        std::vector<XrActionSuggestedBinding> bindings;
        for(int a=0;a<2;++a) {
            XrActionCreateInfo ai{XR_TYPE_ACTION_CREATE_INFO};
            std::strcpy(ai.actionName,a ? "menu" : "stick_click");
            std::strcpy(ai.localizedActionName,ai.actionName); ai.actionType=XR_ACTION_TYPE_BOOLEAN_INPUT;
            ai.countSubactionPaths=2; ai.subactionPaths=hands;
            check(xrCreateAction(set,&ai,&actions[a]),"input action");
            for(int h=0;h<2;++h) {
                std::string path=h ? "/user/hand/right" : "/user/hand/left";
                path+=a ? (h ? "/input/b/click" : "/input/y/click") : "/input/thumbstick/click";
                XrPath p; check(xrStringToPath(instance,path.c_str(),&p),"binding path");
                bindings.push_back({actions[a],p});
            }
        }
        if(std::getenv("METEOR_XR_HAPTICS")) {
            XrActionCreateInfo ai{XR_TYPE_ACTION_CREATE_INFO};
            std::strcpy(ai.actionName,"haptic_proof"); std::strcpy(ai.localizedActionName,"Haptic proof");
            ai.actionType=XR_ACTION_TYPE_VIBRATION_OUTPUT; ai.countSubactionPaths=2; ai.subactionPaths=hands;
            check(xrCreateAction(set,&ai,&haptic),"haptic action");
            for(int hand=0;hand<2;++hand) {
                XrPath path; check(xrStringToPath(instance,hand ? "/user/hand/right/output/haptic" : "/user/hand/left/output/haptic",&path),"haptic path");
                bindings.push_back({haptic,path});
            }
        }
        XrInteractionProfileSuggestedBinding bi{XR_TYPE_INTERACTION_PROFILE_SUGGESTED_BINDING};
        check(xrStringToPath(instance,"/interaction_profiles/oculus/touch_controller",&bi.interactionProfile),"profile");
        bi.countSuggestedBindings=uint32_t(bindings.size()); bi.suggestedBindings=bindings.data();
        check(xrSuggestInteractionProfileBindings(instance,&bi),"input bindings");
        XrSessionActionSetsAttachInfo attach{XR_TYPE_SESSION_ACTION_SETS_ATTACH_INFO};
        attach.countActionSets=1; attach.actionSets=&set;
        check(xrAttachSessionActionSets(session,&attach),"attach input set");
    }
    void observe() {
        if(!observing) return;
        // Polling delivers the runtime's post-begin VISIBLE/FOCUSED changes.
        // Otherwise xrSyncActions can remain SESSION_NOT_FOCUSED forever.
        XrEventDataBuffer event{XR_TYPE_EVENT_DATA_BUFFER};
        XrResult polled;
        while((polled=xrPollEvent(instance,&event))==XR_SUCCESS) {
            if(event.type==XR_TYPE_EVENT_DATA_SESSION_STATE_CHANGED)
                std::printf("APP_SESSION state=%d\n",reinterpret_cast<XrEventDataSessionStateChanged *>(&event)->state);
            event={XR_TYPE_EVENT_DATA_BUFFER};
        }
        check(polled,"observe input events");
        XrActiveActionSet active{set,XR_NULL_PATH}; XrActionsSyncInfo sync{XR_TYPE_ACTIONS_SYNC_INFO};
        sync.countActiveActionSets=1; sync.activeActionSets=&active;
        XrResult result=xrSyncActions(session,&sync); check(result,"observe input sync");
        for(int h=0;h<2;++h) for(int a=0;a<2;++a) {
            XrActionStateGetInfo gi{XR_TYPE_ACTION_STATE_GET_INFO}; gi.action=actions[a]; gi.subactionPath=hands[h];
            XrActionStateBoolean value{XR_TYPE_ACTION_STATE_BOOLEAN};
            check(xrGetActionStateBoolean(session,&gi,&value),"observe input state");
            int state=(value.isActive ? 2 : 0)+(value.currentState ? 1 : 0);
            if(state!=previous[h][a]) {
                std::printf("APP_INPUT hand=%d action=%s active=%u value=%u\n",h,a ? "by_click" : "stick_click",value.isActive,value.currentState);
                previous[h][a]=state;
            }
        }
    }
    void run() {
        if(!enabled) return;
        const unsigned phases[][2]={{0,0},{2,0},{0,0},{0,2},{0,0},{32,0},{0,32},{32,32},{2,2},{0,0}};
        for(const auto &phase:phases) {
            {std::ofstream file(std::getenv("METEOR_CONTROLLER_FIXTURE")); file<<phase[0]<<" "<<phase[1]<<"\n";}
            bool matched=false;
            for(int attempt=0;attempt<90 && !matched;++attempt) {
                XrEventDataBuffer event{XR_TYPE_EVENT_DATA_BUFFER};
                while(xrPollEvent(instance,&event)==XR_SUCCESS) event={XR_TYPE_EVENT_DATA_BUFFER};
                XrFrameWaitInfo wi{XR_TYPE_FRAME_WAIT_INFO}; XrFrameState frame{XR_TYPE_FRAME_STATE};
                check(xrWaitFrame(session,&wi,&frame),"input wait frame");
                XrFrameBeginInfo begin{XR_TYPE_FRAME_BEGIN_INFO}; check(xrBeginFrame(session,&begin),"input begin frame");
                XrActiveActionSet active{set,XR_NULL_PATH}; XrActionsSyncInfo sync{XR_TYPE_ACTIONS_SYNC_INFO};
                sync.countActiveActionSets=1; sync.activeActionSets=&active;
                XrResult result=xrSyncActions(session,&sync); check(result,"input sync");
                matched=result==XR_SUCCESS;
                for(int h=0;h<2;++h) for(int a=0;a<2;++a) {
                    XrActionStateGetInfo gi{XR_TYPE_ACTION_STATE_GET_INFO}; gi.action=actions[a]; gi.subactionPath=hands[h];
                    XrActionStateBoolean value{XR_TYPE_ACTION_STATE_BOOLEAN};
                    check(xrGetActionStateBoolean(session,&gi,&value),"get input state");
                    const bool expected=(phase[h]&(a ? 32 : 2))!=0;
                    matched=matched && value.isActive && bool(value.currentState)==expected;
                    if(attempt==89) std::printf("INPUT_PROBE hand=%d action=%d active=%u value=%u expected=%d\n",h,a,value.isActive,value.currentState,expected);
                }
                XrFrameEndInfo end{XR_TYPE_FRAME_END_INFO}; end.displayTime=frame.predictedDisplayTime; end.environmentBlendMode=XR_ENVIRONMENT_BLEND_MODE_OPAQUE;
                check(xrEndFrame(session,&end),"input end frame");
            }
            if(!matched) {std::fprintf(stderr,"FAIL: input phase left=%u right=%u\n",phase[0],phase[1]); std::exit(1);}
            std::printf("PASS: OpenXR per-hand phase left=%u right=%u\n",phase[0],phase[1]);
        }
        if(haptic!=XR_NULL_HANDLE) {
            for(int hand=0;hand<2;++hand) {
                XrHapticActionInfo info{XR_TYPE_HAPTIC_ACTION_INFO}; info.action=haptic; info.subactionPath=hands[hand];
                XrHapticVibration pulse{XR_TYPE_HAPTIC_VIBRATION}; pulse.amplitude=.4f; pulse.duration=50000000;
                check(xrApplyHapticFeedback(session,&info,reinterpret_cast<const XrHapticBaseHeader *>(&pulse)),"apply haptic");
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
        }
        check(xrRequestExitSession(session),"input exit");
    }
};
