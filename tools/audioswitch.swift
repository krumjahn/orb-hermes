import Foundation
import CoreAudio

// List the audio output devices, and optionally switch the default output.
//   ./audioswitch                      -> list
//   ./audioswitch "MacBook Pro"        -> switch to the first match

func deviceName(_ device: AudioDeviceID) -> String {
    var size = UInt32(MemoryLayout<CFString?>.size)
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioObjectPropertyName,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr else { return "?" }
    var buf: CFString? = nil
    guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &buf) == noErr else { return "?" }
    return (buf as String?) ?? "?"
}

func transport(_ device: AudioDeviceID) -> UInt32 {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyTransportType,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectHasProperty(device, &addr) else { return 0 }
    var t: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &t) == noErr else { return 0 }
    return t
}

let system = AudioObjectID(kAudioObjectSystemObject)
var size = UInt32(0)
var devicesAddr = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDevices,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)
guard AudioObjectGetPropertyDataSize(system, &devicesAddr, 0, nil, &size) == noErr else {
    print("cannot list devices"); exit(1)
}
var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
AudioObjectGetPropertyData(system, &devicesAddr, 0, nil, &size, &devices)

let outputs = devices.filter { transport($0) != 0 || deviceName($0).contains("Speaker") }

var defaultAddr = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDefaultOutputDevice,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)
var current = AudioDeviceID(0)
var csize = UInt32(MemoryLayout<AudioDeviceID>.size)
AudioObjectGetPropertyData(system, &defaultAddr, 0, nil, &csize, &current)

for d in outputs {
    let mark = d == current ? "  <-- default" : ""
    print("\(d)  \(deviceName(d))  transport=\(transport(d))\(mark)")
}

if CommandLine.arguments.count > 1 {
    let wanted = CommandLine.arguments[1].lowercased()
    if let target = outputs.first(where: { deviceName($0).lowercased().contains(wanted) }) {
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var newDevice = target
        let status = AudioObjectSetPropertyData(system, &defaultAddr, 0, nil, size, &newDevice)
        if status == noErr {
            print("switched to \(deviceName(target))")
        } else {
            print("switch failed: \(status)")
            exit(1)
        }
    } else {
        print("no device matching '\(wanted)'")
        exit(1)
    }
}
