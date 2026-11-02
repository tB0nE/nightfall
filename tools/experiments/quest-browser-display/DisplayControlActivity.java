package app.nightfall.browserdisplayprobe;
import android.app.Activity;
import android.os.Bundle;
import android.graphics.Color;
import android.widget.TextView;
/** Non-exported same-UID control for testing activity launch on the display. */
public final class DisplayControlActivity extends Activity {
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        TextView view = new TextView(this);
        view.setBackgroundColor(Color.CYAN); view.setTextColor(Color.BLACK);
        view.setText("Nightfall secondary activity control"); setContentView(view);
    }
}
