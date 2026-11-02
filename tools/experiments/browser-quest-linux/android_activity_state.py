"""Android multi-display activity snapshots; not a proxy for VR visibility."""
def activity_snapshot(output,package='app.nightfall.quest'):
    resumed=[]
    for line in output.splitlines():
        if 'topResumedActivity=' not in line:continue
        value=line.split('topResumedActivity=',1)[1].strip()
        if value and value not in resumed:resumed.append(value)
    app=next((value for value in resumed if package+'/' in value),None)
    return {'resumed_activities':resumed,'nightfall_resumed':app is not None,
            'preferred_activity':app or (resumed[0] if resumed else 'unknown'),
            'limits':'Multiple displays may have resumed activities. This snapshot alone does not establish XR visibility or the cause of a startup timeout.'}
