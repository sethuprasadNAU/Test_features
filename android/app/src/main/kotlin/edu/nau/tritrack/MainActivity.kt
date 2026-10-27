package edu.nau.tritrack

// FlutterFragmentActivity rather than FlutterActivity: local_auth (task 10.79)
// uses BiometricPrompt/FragmentManager under the hood and requires the host
// activity to be a FragmentActivity, even for the isDeviceSupported() check
// this app actually calls.
import io.flutter.embedding.android.FlutterFragmentActivity

class MainActivity : FlutterFragmentActivity()
