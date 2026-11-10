package io.corelo.ghostgpt.rootkitkat;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.DialogInterface;
import android.graphics.Color;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.view.View;
import android.view.ViewGroup;
import android.widget.Button;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

public final class MainActivity extends Activity {
    private final ExecutorService worker = Executors.newSingleThreadExecutor();
    private final Handler ui = new Handler(Looper.getMainLooper());
    private TextView report;

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        LinearLayout layout = new LinearLayout(this);
        layout.setOrientation(LinearLayout.VERTICAL);
        layout.setBackgroundColor(Color.rgb(242,245,250));
        ScrollView scroller = new ScrollView(this);
        scroller.addView(layout);
        setContentView(scroller);
        heading(layout, "GHOST ROOT TOOLS", 22);
        heading(layout, "MW22-A32 · Android 4.4.4 / KitKat", 16);
        heading(layout, "This is a root-management client. It does NOT exploit Android or install root. Your firmware must already provide a working su binary, for example through a functioning SuperSU installation.", 14);
        report = heading(layout, "Root status has not been checked.", 14);
        action(layout, "Check for existing full root (su -c id -u)", new Runnable() {
            @Override public void run() { runRoot("id -u", "Check whether su grants UID 0?", false); }
        });
        action(layout, "Inspect running identity", new Runnable() {
            @Override public void run() { runRoot("id", "Read the root shell identity?", false); }
        });
        action(layout, "Inspect system mount status", new Runnable() {
            @Override public void run() { runRoot("mount", "Inspect mounted filesystems?", false); }
        });
        action(layout, "Inspect build properties", new Runnable() {
            @Override public void run() { runRoot("getprop ro.build.display.id", "Inspect firmware build string?", false); }
        });
        heading(layout, "Advanced root shell · manual confirmation each time", 16);
        final EditText command = new EditText(this);
        command.setHint("Command to run with su -c");
        command.setSingleLine(false);
        layout.addView(command);
        action(layout, "Review custom ROOT command", new Runnable() {
            @Override public void run() {
                String value = command.getText().toString().trim();
                if (value.length() < 1 || value.length() > 400) {
                    report.setText("Enter 1–400 command characters."); return;
                }
                runRoot(value, "This command can permanently damage your device or erase files. It will execute as root only if su already grants access.", true);
            }
        });
        heading(layout, "Rooting this particular model", 16);
        heading(layout, "Some MW22-A32 units reportedly shipped with SuperSU. If the root test returns 0, the app can already request full root. If it fails, do not install random one-click-root APKs or flash unrelated firmware. Root installation requires a firmware-compatible method and a backup.", 14);
        heading(layout, "No hidden commands, background access, or automatic wireless debugging changes.", 13);
    }

    private TextView heading(LinearLayout parent, String text, int size) {
        TextView v = new TextView(this);
        v.setText(text);
        v.setTextSize(size);
        v.setTextColor(Color.rgb(22,32,55));
        v.setPadding(16,16,16,12);
        v.setTextIsSelectable(true);
        parent.addView(v, new LinearLayout.LayoutParams(-1,-2));
        return v;
    }

    private void action(LinearLayout parent, String label, final Runnable run) {
        Button b = new Button(this);
        b.setText(label);
        b.setAllCaps(false);
        b.setOnClickListener(new View.OnClickListener(){
            @Override public void onClick(View v){run.run();}
        });
        parent.addView(b,new LinearLayout.LayoutParams(-1,-2));
    }

    private void runRoot(final String cmd, String explanation, final boolean dangerous) {
        new AlertDialog.Builder(this).setTitle(dangerous ? "Execute privileged command?" : "Authorize root check?")
            .setMessage(explanation + "\n\nsu -c " + cmd)
            .setNegativeButton("Cancel",null)
            .setPositiveButton(dangerous ? "Execute" : "Check",new DialogInterface.OnClickListener(){
                @Override public void onClick(DialogInterface d,int which) {
                    report.setText("Checking root permission...");
                    worker.execute(new Runnable(){
                        @Override public void run() {
                            final String response = execute(cmd);
                            ui.post(new Runnable(){ @Override public void run() {
                                report.setText("$ su -c " + cmd + "\n" + response);
                            }});
                        }
                    });
                }
            }).show();
    }

    private String execute(String command) {
        Process p=null;
        Thread reader=null;
        final ByteArrayOutputStream buffer=new ByteArrayOutputStream();
        try {
            p=new ProcessBuilder("su","-c",command).redirectErrorStream(true).start();
            final InputStream input=p.getInputStream();
            reader=new Thread(new Runnable(){
                @Override public void run(){
                    try {
                        byte[] data=new byte[2048];
                        int count;
                        while((count=input.read(data))!=-1) {
                            synchronized(buffer){
                                if(buffer.size()<8192) buffer.write(data,0,Math.min(count,8192-buffer.size()));
                            }
                        }
                    }catch(Exception ignored){}finally{try{input.close();}catch(Exception ignored){}}
                }
            });
            reader.setDaemon(true);reader.start();
            long until=android.os.SystemClock.uptimeMillis()+20000;
            Integer exit=null;
            while(android.os.SystemClock.uptimeMillis()<until) {
                try{exit=p.exitValue();break;}catch(IllegalThreadStateException running){Thread.sleep(100);}
            }
            if(exit==null) {
                p.destroy();
                return "Timed out after 20 seconds. SuperSU may need local permission approval.";
            }
            if(reader!=null) reader.join(600);
            String output;
            synchronized(buffer){output=new String(buffer.toByteArray(),"UTF-8");}
            if("id -u".equals(command)&&exit==0&&"0".equals(output.trim()))
                output += "\nCONFIRMED: su provided UID 0. Your existing firmware has working root access.";
            return "Exit code " + exit + "\n" + output;
        }catch(Exception failure){return "No usable root shell: " + failure.getMessage();}
        finally{if(p!=null)p.destroy();}
    }

    @Override protected void onDestroy() {worker.shutdownNow();super.onDestroy();}
}
