package me.lucky.wasted.fragment

import android.content.Context
import android.content.SharedPreferences
import android.os.Build
import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import androidx.fragment.app.Fragment

import me.lucky.wasted.Preferences
import me.lucky.wasted.Trigger
import me.lucky.wasted.databinding.FragmentSettingsBinding
import me.lucky.wasted.settings.LocalSettingsApplier

class SettingsFragment : Fragment() {
    private lateinit var binding: FragmentSettingsBinding
    private lateinit var ctx: Context
    private lateinit var prefs: Preferences
    private lateinit var prefsdb: Preferences
    private val applier by lazy { LocalSettingsApplier.create(ctx) }

    private val prefsListener = SharedPreferences.OnSharedPreferenceChangeListener { _, key ->
        prefs.copyTo(prefsdb, key)
    }

    override fun onCreateView(
        inflater: LayoutInflater,
        container: ViewGroup?,
        savedInstanceState: Bundle?,
    ): View {
        binding = FragmentSettingsBinding.inflate(inflater, container, false)
        init()
        setup()
        return binding.root
    }

    override fun onStart() {
        super.onStart()
        prefs.registerListener(prefsListener)
    }

    override fun onStop() {
        super.onStop()
        prefs.unregisterListener(prefsListener)
    }

    private fun init() {
        ctx = requireContext()
        prefs = Preferences(ctx)
        prefsdb = Preferences(ctx, encrypted = false)
        binding.apply {
            val triggers = prefs.triggers
            panicKit.isChecked = triggers.and(Trigger.PANIC_KIT.value) != 0
            tile.isEnabled = Build.VERSION.SDK_INT >= Build.VERSION_CODES.N
            tile.isChecked = triggers.and(Trigger.TILE.value) != 0
            shortcut.isChecked = triggers.and(Trigger.SHORTCUT.value) != 0
            broadcast.isChecked = triggers.and(Trigger.BROADCAST.value) != 0
            notification.isChecked = triggers.and(Trigger.NOTIFICATION.value) != 0
            lock.isChecked = triggers.and(Trigger.LOCK.value) != 0
            usb.isChecked = triggers.and(Trigger.USB.value) != 0
            application.isChecked = triggers.and(Trigger.APPLICATION.value) != 0
        }
    }

    private fun setup() = binding.apply {
        panicKit.setOnCheckedChangeListener { _, isChecked ->
            applier.setTrigger(Trigger.PANIC_KIT, isChecked)
        }
        tile.setOnCheckedChangeListener { _, isChecked ->
            applier.setTrigger(Trigger.TILE, isChecked)
        }
        shortcut.setOnCheckedChangeListener { _, isChecked ->
            applier.setTrigger(Trigger.SHORTCUT, isChecked)
        }
        broadcast.setOnCheckedChangeListener { _, isChecked ->
            applier.setTrigger(Trigger.BROADCAST, isChecked)
        }
        notification.setOnCheckedChangeListener { _, isChecked ->
            applier.setTrigger(Trigger.NOTIFICATION, isChecked)
        }
        lock.setOnCheckedChangeListener { _, isChecked ->
            applier.setTrigger(Trigger.LOCK, isChecked)
        }
        usb.setOnCheckedChangeListener { _, isChecked ->
            applier.setTrigger(Trigger.USB, isChecked)
        }
        application.setOnCheckedChangeListener { _, isChecked ->
            applier.setTrigger(Trigger.APPLICATION, isChecked)
        }
    }
}
