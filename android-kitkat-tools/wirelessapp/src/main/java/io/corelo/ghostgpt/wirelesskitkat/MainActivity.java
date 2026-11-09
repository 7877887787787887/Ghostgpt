package io.corelo.ghostgpt.wirelesskitkat;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.DialogInterface;
import android.graphics.Color;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.Build;
import android.provider.Settings;
import android.content.Intent;
import android.view.View;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.net.Inet4Address;
import java.net.InetAddress;
import java.net.NetworkInterface;
import java.util.Collections;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

public final class MainActivity extends Activity {
    private final ExecutorService worker=Executors.newSingleThreadExecutor();
    private final Handler ui=new Handler(Looper.getMainLooper());
    private TextView report;

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        LinearLayout main=new LinearLayout(this);
        main.setOrientation(LinearLayout.VERTICAL);
        main.setBackgroundColor(Color.rgb(242,245,250));
        ScrollView scroll=new ScrollView(this);
        scroll.addView(main);
        setContentView(scroll);
        label(main,"GHOST WIRELESS ADB",22);
        label(main,"Android 4.4.4 / MW22-A32",16);
        label(main,"Wireless debugging on KitKat uses legacy ADB TCP, not Android 11 pairing. Enabling port 5555 exposes remote debugging to devices that can reach your network. Use only a private trusted Wi-Fi connection and disable it after use.",14);
        report=label(main,"Status not yet checked.",14);
        button(main,"Refresh ADB / root / IP status",new Runnable(){
            @Override public void run(){refresh();}
        });
        button(main,"Enable wireless ADB (ROOT REQUIRED)",new Runnable(){
            @Override public void run() {
                confirm(true);
            }
        });
        button(main,"Disable wireless ADB (ROOT REQUIRED)",new Runnable(){
            @Override public void run(){confirm(false);}
        });
        button(main,"Open Developer options",new Runnable(){
            @Override public void run(){
                try{startActivity(new Intent(Settings.ACTION_APPLICATION_DEVELOPMENT_SETTINGS));}
                catch(Exception problem){report.setText("Developer settings are hidden on this firmware.");}
            }
        });
        label(main,"If root does not work, first connect this tablet to a trusted Windows PC over a data-capable USB cable, enable USB debugging on the tablet and approve its RSA key prompt. On the PC run 'adb devices' and then 'adb tcpip 5555'; connect using 'adb connect TABLET_IP:5555'. This app cannot silently bypass that authorization.",14);
        label(main,"This tool does not install su, exploit firmware, permanently change startup settings, open a public port, or grant automatic remote access.",13);
    }

    private TextView label(LinearLayout layout,String value,int size){
        TextView text=new TextView(this);
        text.setText(value);text.setTextSize(size);
        text.setTextColor(Color.rgb(22,32,55));
        text.setTextIsSelectable(true);text.setPadding(16,16,16,12);
        layout.addView(text,new LinearLayout.LayoutParams(-1,-2));
        return text;
    }

    private void button(LinearLayout layout,String value,final Runnable act){
        Button b=new Button(this);b.setText(value);b.setAllCaps(false);
        b.setOnClickListener(new View.OnClickListener(){@Override public void onClick(View view){act.run();}});
        layout.addView(b,new LinearLayout.LayoutParams(-1,-2));
    }

    private void refresh(){
        report.setText("Reading ADB state...");
        worker.execute(new Runnable(){@Override public void run(){
            final String result=status();
            ui.post(new Runnable(){@Override public void run(){report.setText(result);}});
        }});
    }

    private String status(){
        StringBuilder result=new StringBuilder();
        result.append("Model: ").append(Build.MODEL).append("\n");
        result.append("Android: ").append(Build.VERSION.RELEASE).append("\n");
        result.append("IP: ").append(ips()).append("\n");
        result.append("ADB TCP port: ").append(getprop("service.adb.tcp.port")).append("\n");
        result.append("ADB service: ").append(getprop("init.svc.adbd")).append("\n");
        try{int flag=Settings.Global.getInt(getContentResolver(),Settings.Global.ADB_ENABLED,-1);
            result.append("ADB setting: ").append(flag==1?"enabled":flag==0?"disabled":"unknown").append("\n");
        }catch(Exception err){result.append("ADB setting: restricted\n");}
        return result.toString();
    }

    private void confirm(final boolean enable){
        String explanation=enable ?
            "Enable ADB over TCP on port 5555? This creates a network-accessible debugging service. Only use on an isolated private network and disable afterwards. Requires pre-existing root permission through su." :
            "Disable ADB TCP mode and return adbd to USB mode? This will disconnect any current wireless ADB session. Requires pre-existing root permission through su.";
        new AlertDialog.Builder(this).setTitle(enable?"Enable wireless debugging?":"Disable wireless debugging?")
            .setMessage(explanation)
            .setNegativeButton("Cancel",null)
            .setPositiveButton(enable?"Enable":"Disable",new DialogInterface.OnClickListener(){
                @Override public void onClick(DialogInterface d,int which) {
                    report.setText("Requesting existing root manager approval...");
                    worker.execute(new Runnable(){@Override public void run(){
                        final String result=modify(enable);
                        ui.post(new Runnable(){@Override public void run(){report.setText(result);}});
                    }});
                }
            }).show();
    }

    private String modify(boolean enable){
        String check=runCommand(new String[]{"su","-c","id -u"},12000);
        if(!check.startsWith("0\n"))return "Root is not available. The tablet's existing su/SuperSU must authorize UID 0 first.\n"+check;
        String command=enable?
            "setprop service.adb.tcp.port 5555; stop adbd; start adbd":
            "setprop service.adb.tcp.port -1; stop adbd; start adbd";
        String response=runCommand(new String[]{"su","-c",command},15000);
        return (enable?"Enable request":"Disable request")+"\n"+response+"\n"+status();
    }

    private static String getprop(String name){
        String r=runCommand(new String[]{"getprop",name},3500);
        if(!r.startsWith("0\n"))return "Unavailable";
        String value=r.substring(2).trim();
        return value.length()==0?"Not set":value;
    }

    private static String runCommand(String[] argv,long timeout){
        Process p=null;
        Thread collector=null;
        final ByteArrayOutputStream capture=new ByteArrayOutputStream();
        try{
            p=new ProcessBuilder(argv).redirectErrorStream(true).start();
            final InputStream stream=p.getInputStream();
            collector=new Thread(new Runnable(){@Override public void run(){
                try{
                    byte[] block=new byte[1024];int n;
                    while((n=stream.read(block))!=-1) {
                        synchronized(capture){if(capture.size()<4096)capture.write(block,0,Math.min(n,4096-capture.size()));}
                    }
                }catch(Exception ignored){}finally{try{stream.close();}catch(Exception ignored){}}
            }});
            collector.setDaemon(true);collector.start();
            long until=android.os.SystemClock.uptimeMillis()+timeout;
            Integer exit=null;
            while(android.os.SystemClock.uptimeMillis()<until){
                try{exit=p.exitValue();break;}catch(IllegalThreadStateException running){Thread.sleep(100);}
            }
            if(exit==null){p.destroy();return "Timed out; check root manager approval or firmware compatibility";}
            collector.join(600);
            String stdout;
            synchronized(capture){stdout=new String(capture.toByteArray(),"UTF-8");}
            return exit+"\n"+stdout;
        }catch(Exception error){return "Unavailable: "+error.getMessage();}
        finally{if(p!=null)p.destroy();}
    }

    private static String ips(){
        StringBuilder b=new StringBuilder();
        try{
            for(NetworkInterface ni:Collections.list(NetworkInterface.getNetworkInterfaces())){
                if(!ni.isUp()||ni.isLoopback())continue;
                for(InetAddress ip:Collections.list(ni.getInetAddresses())){
                    if(ip instanceof Inet4Address && !ip.isLoopbackAddress())
                        b.append(ni.getName()).append(" ").append(ip.getHostAddress()).append(" ");
                }
            }
        }catch(Exception err){return "Unavailable";}
        return b.length()==0?"No IPv4 address":b.toString();
    }

    @Override protected void onDestroy(){worker.shutdownNow();super.onDestroy();}
}
