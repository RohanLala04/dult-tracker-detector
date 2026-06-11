package edu.usc.rklala.dultemulator

import android.Manifest
import android.app.Activity
import android.bluetooth.BluetoothManager
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertisingSet
import android.bluetooth.le.AdvertisingSetCallback
import android.bluetooth.le.AdvertisingSetParameters
import android.bluetooth.le.BluetoothLeAdvertiser
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.ParcelUuid
import android.widget.Button
import android.widget.TextView

/**
 * Broadcasts the DULT location-enabled BLE payload
 * (draft-ledvina-apple-google-unwanted-trackers-02) so the macOS detector
 * has an over-the-air tracker to find.
 *
 * The payload is carried under the test-beacon UUID 0xFC99 rather than the
 * real DULT UUID 0xFCB2. Android's Bluetooth stack silently strips 0xFCB2
 * service data from third-party app advertisements (an anti-abuse measure
 * that prevents apps from impersonating location trackers), so a phone
 * cannot emit a real DULT advertisement. 0xFC99 is not filtered and is
 * confirmed to reach macOS Core Bluetooth; the detector parses it with the
 * identical DULT logic and labels it "TEST".
 *
 * Service data payload (same as the DULT spec, Table 1):
 *   byte 0: network ID 0x01 = Apple (Table 24)
 *   byte 1: status byte 0x00 - near-owner bit (LSB) = 0 = separated (Table 3)
 */
class MainActivity : Activity() {

    private companion object {
        /// Test-beacon UUID 0xFC99 expanded onto the Bluetooth base UUID.
        /// Carries the DULT payload because Android strips 0xFCB2 (see above).
        val BEACON_UUID: ParcelUuid =
            ParcelUuid.fromString("0000FC99-0000-1000-8000-00805F9B34FB")

        /// network ID 0x01 (Apple), status byte 0x00 (separated).
        val SEPARATED_PAYLOAD = byteArrayOf(0x01, 0x00)

        const val PERMISSION_REQUEST = 1
    }

    private lateinit var statusText: TextView
    private lateinit var startButton: Button
    private lateinit var stopButton: Button

    private var advertiser: BluetoothLeAdvertiser? = null
    private var advertising = false

    private val advertiseCallback = object : AdvertisingSetCallback() {
        override fun onAdvertisingSetStarted(
            advertisingSet: AdvertisingSet?,
            txPower: Int,
            status: Int,
        ) {
            if (status == ADVERTISE_SUCCESS) {
                advertising = true
                updateUi("Broadcasting DULT advertisement (Separated, network: Apple)")
            } else {
                advertising = false
                updateUi("Failed to start: status $status")
            }
        }

        override fun onAdvertisingSetStopped(advertisingSet: AdvertisingSet?) {
            advertising = false
            updateUi(getString(R.string.status_idle))
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)
        statusText = findViewById(R.id.statusText)
        startButton = findViewById(R.id.startButton)
        stopButton = findViewById(R.id.stopButton)

        startButton.setOnClickListener { startBroadcast() }
        stopButton.setOnClickListener { stopBroadcast() }
    }

    override fun onDestroy() {
        super.onDestroy()
        stopBroadcast()
    }

    private fun requiredPermissions(): Array<String> =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            arrayOf(Manifest.permission.BLUETOOTH_ADVERTISE, Manifest.permission.BLUETOOTH_CONNECT)
        } else {
            emptyArray()
        }

    private fun hasPermissions(): Boolean = requiredPermissions().all {
        checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED
    }

    private fun startBroadcast() {
        if (!hasPermissions()) {
            requestPermissions(requiredPermissions(), PERMISSION_REQUEST)
            return
        }

        val adapter = (getSystemService(BLUETOOTH_SERVICE) as BluetoothManager).adapter
        if (adapter == null || !adapter.isEnabled) {
            updateUi("Turn on Bluetooth first (Settings > Connections > Bluetooth)")
            return
        }
        val leAdvertiser = adapter.bluetoothLeAdvertiser
        if (leAdvertiser == null) {
            updateUi("This phone does not support BLE advertising")
            return
        }
        advertiser = leAdvertiser

        // Legacy PHY for macOS/iOS compatibility; non-scannable so every AD
        // structure rides in the primary advertising packet.
        val parameters = AdvertisingSetParameters.Builder()
            .setLegacyMode(true)
            .setConnectable(false)
            .setScannable(false)
            .setInterval(AdvertisingSetParameters.INTERVAL_LOW)
            .setTxPowerLevel(AdvertisingSetParameters.TX_POWER_HIGH)
            .build()

        // Device name excluded to keep the packet inside the 31-byte legacy
        // advertisement budget.
        val data = AdvertiseData.Builder()
            .setIncludeDeviceName(false)
            .setIncludeTxPowerLevel(false)
            .addServiceData(BEACON_UUID, SEPARATED_PAYLOAD)
            .build()

        updateUi("Starting...")
        leAdvertiser.startAdvertisingSet(parameters, data, null, null, null, advertiseCallback)
    }

    private fun stopBroadcast() {
        advertiser?.stopAdvertisingSet(advertiseCallback)
        advertising = false
        updateUi(getString(R.string.status_idle))
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != PERMISSION_REQUEST) return
        if (grantResults.all { it == PackageManager.PERMISSION_GRANTED }) {
            startBroadcast()
        } else {
            updateUi("Bluetooth permission denied - allow it to broadcast")
        }
    }

    private fun updateUi(status: String) {
        statusText.text = status
        startButton.isEnabled = !advertising
        stopButton.isEnabled = advertising
    }
}
