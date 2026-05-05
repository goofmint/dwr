#!/usr/bin/env bash
# Lists CoreAudio input devices (the names that SoX `rec -t coreaudio "<name>"`
# will accept). The default input is marked with a leading "*".
set -euo pipefail

swift -e '
import CoreAudio
import Foundation

let systemObj = AudioObjectID(kAudioObjectSystemObject)

func prop(_ sel: AudioObjectPropertySelector,
          _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

var defAddr = prop(kAudioHardwarePropertyDefaultInputDevice)
var defID: AudioDeviceID = 0
var defSize = UInt32(MemoryLayout<AudioDeviceID>.size)
AudioObjectGetPropertyData(systemObj, &defAddr, 0, nil, &defSize, &defID)

var devsAddr = prop(kAudioHardwarePropertyDevices)
var listSize: UInt32 = 0
AudioObjectGetPropertyDataSize(systemObj, &devsAddr, 0, nil, &listSize)
let count = Int(listSize) / MemoryLayout<AudioDeviceID>.size
var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
AudioObjectGetPropertyData(systemObj, &devsAddr, 0, nil, &listSize, &deviceIDs)

for id in deviceIDs {
    var inAddr = prop(kAudioDevicePropertyStreamConfiguration, kAudioDevicePropertyScopeInput)
    var inSize: UInt32 = 0
    if AudioObjectGetPropertyDataSize(id, &inAddr, 0, nil, &inSize) != 0 || inSize == 0 { continue }
    let bl = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(inSize))
    defer { bl.deallocate() }
    if AudioObjectGetPropertyData(id, &inAddr, 0, nil, &inSize, bl) != 0 { continue }
    var ch: UInt32 = 0
    for b in UnsafeMutableAudioBufferListPointer(bl) { ch += b.mNumberChannels }
    if ch == 0 { continue }

    var nameAddr = prop(kAudioDevicePropertyDeviceNameCFString)
    var name: CFString?
    var ns = UInt32(MemoryLayout<CFString?>.size)
    let r = withUnsafeMutablePointer(to: &name) { p in
        AudioObjectGetPropertyData(id, &nameAddr, 0, nil, &ns, p)
    }
    let nameStr = (r == 0 ? (name as String?) : nil) ?? "<unknown>"
    print("\(id == defID ? "* " : "  ")\(nameStr) (\(ch)ch)")
}
'
