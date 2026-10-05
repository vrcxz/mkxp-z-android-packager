package com.hatkid.mkxpz;

import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ActivityInfo;
import android.content.pm.PackageManager;
import android.view.KeyEvent;
import android.view.MotionEvent;
import android.view.InputDevice;
import android.os.Build;
import android.os.Bundle;
import android.os.Environment;
import android.os.Vibrator;
import android.os.VibrationEffect;
import android.os.storage.StorageManager;
import android.os.storage.OnObbStateChangeListener;
import android.net.Uri;
import android.provider.Settings;
import android.util.Log;
import java.util.Locale;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import android.content.res.AssetManager;
import android.widget.Toast;

import org.libsdl.app.SDLActivity;
import com.hatkid.mkxpz.gamepad.Gamepad;
import com.hatkid.mkxpz.gamepad.GamepadConfig;

public class MainActivity extends SDLActivity
{
    // This activity inherits from SDLActivity activity.
    // Put your Java-side stuff here.

    private static final String TAG = "mkxp-z[Activity]";
    private static final String GAME_PATH_DEFAULT = Environment.getExternalStorageDirectory() + "/mkxp-z";
    private static String GAME_PATH = GAME_PATH_DEFAULT;
    private static String OBB_MAIN_FILENAME;
    private static boolean DEBUG = false;

    // Bundled game (APK assets) extraction
    private static final String ASSETS_GAME_DIR = "game";
    private static final String EXTRACTED_DIR = "game";
    private static final String EXTRACT_MARKER = ".extract_ok";

    protected boolean mStarted = false;

    private StorageManager mStorageManager;

    // In-screen gamepad
    private final Gamepad mGamepad = new Gamepad();
    private boolean mGamepadInvisible = false;

    /** True when the APK ships a game under assets/game. */
    private boolean hasBundledAssets()
    {
        try {
            String[] entries = getAssets().list(ASSETS_GAME_DIR);
            return entries != null && entries.length > 0;
        } catch (IOException e) {
            return false;
        }
    }

    /** True when the extracted copy matches the current APK version. */
    private boolean markerIsCurrent()
    {
        try {
            File marker = new File(getFilesDir(), EXTRACTED_DIR + "/" + EXTRACT_MARKER);
            if (!marker.exists()) {
                return false;
            }
            String stored = new String(java.nio.file.Files.readAllBytes(marker.toPath())).trim();
            return stored.equals(String.valueOf(BuildConfig.VERSION_CODE));
        } catch (Exception e) {
            return false;
        }
    }

    /** Blocking extraction of the bundled game into the app's private files dir. */
    private boolean extractBundledGame()
    {
        AssetManager am = getAssets();
        File dest = new File(getFilesDir(), EXTRACTED_DIR);
        try {
            String[] entries = am.list(ASSETS_GAME_DIR);
            if (entries == null || entries.length == 0) {
                return false;
            }
        } catch (IOException e) {
            return false;
        }
        Log.i(TAG, "Extracting bundled game from APK assets to " + dest);
        if (dest.exists()) {
            deleteRecursive(dest);
        }
        //noinspection ResultOfMethodCallIgnored
        dest.mkdirs();
        try {
            extractAssetDir(am, ASSETS_GAME_DIR, dest);
            FileOutputStream fos = new FileOutputStream(new File(dest, EXTRACT_MARKER));
            try {
                fos.write(String.valueOf(BuildConfig.VERSION_CODE).getBytes());
            } finally {
                fos.close();
            }
        } catch (Exception e) {
            Log.e(TAG, "Failed to extract bundled game", e);
            return false;
        }
        return true;
    }

    private void extractAssetDir(AssetManager am, String assetPath, File outDir) throws IOException
    {
        String[] entries = am.list(assetPath);
        if (entries == null || entries.length == 0) {
            // It is a file
            copyAssetFile(am, assetPath, outDir);
            return;
        }
        //noinspection ResultOfMethodCallIgnored
        outDir.mkdirs();
        for (String entry : entries) {
            String childAsset = assetPath + "/" + entry;
            File childOut = new File(outDir, entry);
            String[] subEntries = am.list(childAsset);
            if (subEntries != null && subEntries.length > 0) {
                extractAssetDir(am, childAsset, childOut);
            } else {
                copyAssetFile(am, childAsset, childOut);
            }
        }
    }

    private void copyAssetFile(AssetManager am, String assetPath, File outFile) throws IOException
    {
        File parent = outFile.getParentFile();
        if (parent != null) {
            //noinspection ResultOfMethodCallIgnored
            parent.mkdirs();
        }
        InputStream in = am.open(assetPath);
        FileOutputStream out = new FileOutputStream(outFile);
        byte[] buffer = new byte[1024 * 512];
        int n;
        while ((n = in.read(buffer)) != -1) {
            out.write(buffer, 0, n);
        }
        out.close();
        in.close();
    }

    private void deleteRecursive(File f)
    {
        if (f.isDirectory()) {
            File[] children = f.listFiles();
            if (children != null) {
                for (File c : children) {
                    deleteRecursive(c);
                }
            }
        }
        //noinspection ResultOfMethodCallIgnored
        f.delete();
    }

    private void runSDLThread()
    {
        if (!mStarted) {
            Log.i(TAG, "Game path: " + GAME_PATH);
        }

        mStarted = true;

        // Run (resume) native SDL thread
        if (mHasMultiWindow) {
            resumeNativeThread();
        }
    }

    OnObbStateChangeListener obbListener = new OnObbStateChangeListener()
    {
        @Override
        public void onObbStateChange(String path, int state)
        {
            super.onObbStateChange(path, state);

            Log.v(TAG, "OBB state of " + path + " changed to " + state);

            switch (state)
            {
                case OnObbStateChangeListener.MOUNTED:
                    String obbPath = mStorageManager.getMountedObbPath(path);
                    Log.v(TAG, "OBB " + path + " is mounted to " + obbPath);
                    GAME_PATH = obbPath;
                    break;

                case OnObbStateChangeListener.UNMOUNTED:
                    Log.v(TAG, "OBB " + path + " is unmounted");
                    GAME_PATH = GAME_PATH_DEFAULT;
                    break;

                default:
                    Log.e(TAG, "Failed to mount OBB " + path + ": Got state " + state);
                    break;
            }

            runSDLThread();
        }
    };

    @Override
    protected void onCreate(Bundle savedInstanceState)
    {
        super.onCreate(savedInstanceState);

        mStorageManager = (StorageManager) getSystemService(STORAGE_SERVICE);

        // Get main OBB filepath
        final String obbPrefix = "main"; // "main", "patch"
        final int obbVersion = 1;
        OBB_MAIN_FILENAME = getObbDir() + "/" + obbPrefix + "." + obbVersion + "." + getPackageName() + ".obb";

        // Get Debug flag
        try {
            ActivityInfo actInfo = getPackageManager().getActivityInfo(this.getComponentName(), PackageManager.GET_META_DATA);
            DEBUG = actInfo.metaData.getBoolean("mkxp_debug");
        } catch (PackageManager.NameNotFoundException e) {
            Log.w(TAG, "Failed to set debug flag: " + e);
            e.printStackTrace();
        }

        // Setup in-screen gamepad
        mGamepadInvisible = (isAndroidTV() || isChromebook());
        GamepadConfig gpadConfig = new GamepadConfig();
        mGamepad.init(gpadConfig, mGamepadInvisible);
        mGamepad.setOnKeyDownListener(SDLActivity::onNativeKeyDown);
        mGamepad.setOnKeyUpListener(SDLActivity::onNativeKeyUp);

        if (mLayout != null) {
            mGamepad.attachTo(this, mLayout);
        }
    }

    @Override
    protected void onStart()
    {
        super.onStart();

        if (!mStarted) {
            // Check for main OBB file
            if (new File(OBB_MAIN_FILENAME).exists()) {
                Log.v(TAG, "Main OBB file found, starting with main OBB mount");

                // Try to mount main OBB file
                mStorageManager.mountObb(OBB_MAIN_FILENAME, null, obbListener);
            } else {
                Log.v(TAG, "Main OBB file not found");

                // Prefer the game bundled in the APK; fall back to external storage
                File dest = new File(getFilesDir(), EXTRACTED_DIR);
                if (new File(dest, EXTRACT_MARKER).exists() && markerIsCurrent()) {
                    GAME_PATH = dest.getAbsolutePath();
                    Log.i(TAG, "Using bundled game at " + GAME_PATH);
                    runSDLThread();
                } else if (hasBundledAssets()) {
                    GAME_PATH = dest.getAbsolutePath();
                    Log.i(TAG, "Extracting bundled game to " + GAME_PATH);
                    Toast.makeText(this, "Preparing game files, please wait...", Toast.LENGTH_LONG).show();
                    final Activity activity = this;
                    new Thread(() -> {
                        if (!extractBundledGame()) {
                            Log.e(TAG, "Bundled game extraction failed");
                        }
                        activity.runOnUiThread(() -> runSDLThread());
                    }).start();
                } else {
                    Log.v(TAG, "No bundled game assets, starting from " + GAME_PATH);
                    runSDLThread();
                }
            }
        } else {
            // onStart: Resume SDL thread
            runSDLThread();
        }
    }

    @Override
    protected void onDestroy()
    {
        super.onDestroy();

        // HACK: Exiting the JVM (process) since Ruby does not likes when we
        // trying to re-initialize Ruby VM in mkxp-z (JNI native library)
        // that leads to segmentation fault, even we have cleanup the Ruby VM.
        System.exit(0);
    }

    @Override
    public boolean dispatchKeyEvent(KeyEvent evt)
    {
        if (
            evt.getKeyCode() != KeyEvent.KEYCODE_BACK &&
            evt.getKeyCode() != KeyEvent.KEYCODE_VOLUME_UP &&
            evt.getKeyCode() != KeyEvent.KEYCODE_VOLUME_DOWN &&
            evt.getKeyCode() != KeyEvent.KEYCODE_VOLUME_MUTE
        ) {
            // Hide gamepad view on key events when visible
            if (!mGamepadInvisible) {
                mGamepad.hideView();
                mGamepadInvisible = true;
            }
        }

        if (mGamepad.processGamepadEvent(evt))
            return true;

        return super.dispatchKeyEvent(evt);
    }

    @Override
    public boolean dispatchTouchEvent(MotionEvent evt)
    {
        // Show gamepad view on touch when hidden
        if (mGamepadInvisible) {
            mGamepad.showView();
            mGamepadInvisible = false;
        }

        return super.dispatchTouchEvent(evt);
    }

    @Override
    public boolean onGenericMotionEvent(MotionEvent evt)
    {
        if (mGamepad.processDPadEvent(evt))
            return true;

        return super.onGenericMotionEvent(evt);
    }

    /**
     * This method is for arguments for launching native mkxp-z.
     * 
     * @return arguments for the mkxp-z
     */
    @Override
    protected String[] getArguments()
    {
        String[] args;

        if (DEBUG) {
            // Arguments in Debug mode
            args = new String[] { "debug" };
        } else {
            // Arguments in normal mode
            args = new String[] {};
        }

        return args;
    }

    /**
     * This static method is used in native mkxp-z. (see systemImpl.cpp)
     * This method returns a string of current device locale tag. (e.g. "en_US")
     * 
     * @return string of locale tag
     */
    @SuppressWarnings("unused")
    private static String getSystemLanguage()
    {
        return Locale.getDefault().toString();
    }

    /**
     * This static method is used in native mkxp-z. (see android-binding.cpp)
     * This method returns a boolean indicating that the device has a vibrator or not.
     * 
     * @return boolean
     */
    @SuppressWarnings("unused")
    private static boolean hasVibrator()
    {
        Vibrator vib = (Vibrator) getContext().getSystemService(Context.VIBRATOR_SERVICE);
        return vib.hasVibrator();
    }

    /**
     * This static method is used in native mkxp-z. (see android-binding.cpp)
     * This method makes device vibrating with given milliseconds duration.
     * 
     * @param duration milliseconds duration of vibration
     */
    @SuppressWarnings("unused")
    private static void vibrate(int duration)
    {
        Vibrator vib = (Vibrator) getContext().getSystemService(Context.VIBRATOR_SERVICE);

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            vib.vibrate(VibrationEffect.createOneShot(duration, VibrationEffect.EFFECT_HEAVY_CLICK));
        } else {
            vib.vibrate(duration);
        }
    }

    /**
     * This static method is used in native mkxp-z. (see android-binding.cpp)
     * This method turns off the current device vibration.
     */
    @SuppressWarnings("unused")
    private static void vibrateStop()
    {
        Vibrator vib = (Vibrator) getContext().getSystemService(Context.VIBRATOR_SERVICE);
        vib.cancel();
    }

    /**
     * This static method is used in native mkxp-z. (see android-binding.cpp)
     * This method returns a boolean indicating the app is in multi window mode or not.
     * (Multi-window mode supports from Android 7.0 Nougat (API 24) and higher.)
     * 
     * @param activity current MainActivity instance
     * @return boolean
     */
    @SuppressWarnings("unused")
    private static boolean inMultiWindow(Activity activity)
    {
        return Build.VERSION.SDK_INT >= Build.VERSION_CODES.N && activity.isInMultiWindowMode();
    }
}