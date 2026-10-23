#pragma once
// Real loader/runtime action-state proof, independent of the game's bindings.
struct MeteorInputProbe {
    XrInstance instance;
    XrSession session;
    XrActionSet set=XR_NULL_HANDLE;
    XrAction actions[2]{};
    XrPath hands[2]{};
    bool enabled=false;
    MeteorInputProbe(XrInstance inst,XrSession sess):instance(inst),session(sess) {
        enabled=std::getenv("METEOR_CONTROLLER_FIXTURE")!=nullptr;
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
        XrInteractionProfileSuggestedBinding bi{XR_TYPE_INTERACTION_PROFILE_SUGGESTED_BINDING};
        check(xrStringToPath(instance,"/interaction_profiles/oculus/touch_controller",&bi.interactionProfile),"profile");
        bi.countSuggestedBindings=uint32_t(bindings.size()); bi.suggestedBindings=bindings.data();
        check(xrSuggestInteractionProfileBindings(instance,&bi),"input bindings");
        XrSessionActionSetsAttachInfo attach{XR_TYPE_SESSION_ACTION_SETS_ATTACH_INFO};
        attach.countActionSets=1; attach.actionSets=&set;
        check(xrAttachSessionActionSets(session,&attach),"attach input set");
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
        check(xrRequestExitSession(session),"input exit");
    }
};
