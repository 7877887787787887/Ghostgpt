package io.corelo.ghostgpt.kitkat;

import android.content.Context;
import android.os.Build;
import android.os.Environment;
import android.os.StatFs;
import android.os.SystemClock;
import android.text.format.DateFormat;
import java.io.File;
import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.Locale;
import java.util.TimeZone;
import javax.net.ssl.HttpsURLConnection;
import java.net.URL;
import java.net.HttpURLConnection;
import java.security.cert.CertificateException;
import javax.net.ssl.SSLHandshakeException;

/** On-demand, read-only health + certificate checks compatible with Android API 19. */
final class DeviceDiagnostics {
    private DeviceDiagnostics() {}

    static String health(Context ctx) {
        StringBuilder b = new StringBuilder();
        b.append("GHOST TABLET HEALTH REPORT\n");
        b.append("Device: ").append(Build.MANUFACTURER).append(" / ").append(Build.MODEL).append("\n");
        b.append("Android: ").append(Build.VERSION.RELEASE).append(" (API ").append(Build.VERSION.SDK_INT).append(")\n");
        b.append("Build: ").append(Build.DISPLAY).append("\n");
        b.append("Time: ").append(new SimpleDateFormat("yyyy-MM-dd HH:mm:ss z",Locale.US).format(new Date())).append("\n");
        b.append("Timezone ID: ").append(TimeZone.getDefault().getID()).append("\n");
        b.append("Uptime: ").append(SystemClock.elapsedRealtime()/60000).append(" min\n\n");
        android.app.ActivityManager manager = (android.app.ActivityManager) ctx.getSystemService(Context.ACTIVITY_SERVICE);
        if(manager!=null){
            android.app.ActivityManager.MemoryInfo mem=new android.app.ActivityManager.MemoryInfo();
            manager.getMemoryInfo(mem);
            b.append("Memory available: ").append(format(mem.availMem)).append("\n");
            b.append("Memory total: ").append(format(mem.totalMem)).append("\n");
            b.append("Low-memory flag: ").append(mem.lowMemory).append("\n");
        }
        appendDisk(b,"Internal storage",Environment.getDataDirectory());
        appendDisk(b,"SD / shared storage",Environment.getExternalStorageDirectory());
        b.append("\nRunning processes (self-reported by Android):\n");
        try {
            if(manager!=null && manager.getRunningAppProcesses()!=null){
                int count=0;
                for(android.app.ActivityManager.RunningAppProcessInfo item:manager.getRunningAppProcesses()){
                    if(count++>=15){b.append("(more omitted)\n");break;}
                    b.append(item.processName).append(" (importance ").append(item.importance).append(")\n");
                }
            }
        }catch(Exception e){b.append("Not available: ").append(e.getClass().getSimpleName()).append("\n");}
        b.append("\nNo files deleted, apps stopped, or settings changed.\n");
        return b.toString();
    }

    private static String format(long bytes) {
        if(bytes<0)return "unknown";
        return String.format(Locale.US,"%.1f MB",bytes/(1024.0*1024.0));
    }

    private static void appendDisk(StringBuilder b,String name,File location){
        try{
            StatFs fs=new StatFs(location.getAbsolutePath());
            long size=fs.getBlockSizeLong(),total=fs.getBlockCountLong(),free=fs.getAvailableBlocksLong();
            b.append(name).append(": ").append(format(total*size)).append(" total, ")
               .append(format(free*size)).append(" free\n");
        }catch(Exception error){b.append(name).append(": unavailable\n");}
    }

    static String tls(Context ctx,String host){
        // This is a certificate validation test, never a bypass.
        if(!"valid-isrgrootx1.letsencrypt.org".equals(host)
            && !"www.google.com".equals(host)
            && !"letsencrypt.org".equals(host))
            return "This diagnostic only tests a fixed allowlist of public HTTPS endpoints.";
        StringBuilder b=new StringBuilder();
        b.append("HTTPS certificate validation test\n");
        b.append("Host: https://").append(host).append("/\n");
        b.append("Android: ").append(Build.VERSION.RELEASE).append("\n");
        b.append("Local clock: ").append(new SimpleDateFormat("yyyy-MM-dd HH:mm:ss z",Locale.US).format(new Date())).append("\n");
        b.append("Timezone: ").append(TimeZone.getDefault().getID()).append("\n");
        HttpURLConnection connection=null;
        try{
            connection=(HttpURLConnection)new URL("https://"+host+"/").openConnection();
            connection.setConnectTimeout(7000);
            connection.setReadTimeout(7000);
            connection.setInstanceFollowRedirects(false);
            int status=connection.getResponseCode();
            b.append("TLS handshake and certificate validation: SUCCESS\n");
            b.append("HTTP response: ").append(status).append("\n");
        }catch(SSLHandshakeException e){
            b.append("TLS handshake: FAILED (certificate trust or protocol compatibility)\n");
            b.append(e.getClass().getSimpleName()).append(": ").append(e.getMessage()).append("\n");
        }catch(Exception e){
            b.append("Connection failed: ").append(e.getClass().getSimpleName()).append("\n");
            b.append(e.getMessage()).append("\n");
        }finally{if(connection!=null)connection.disconnect();}
        b.append("\nNever turn off certificate validation. Check the system clock and trusted CA chain first.\n");
        return b.toString();
    }
}
