# res://scripts/resources/cloak_audio_data.gd
class_name CloakAudioData
extends Resource

@export_group("Sounds")
@export var sound_cloak:   AudioStream = null
@export var sound_decloak: AudioStream = null

@export_group("Volume")
@export_range(-30.0, 200.0, 0.1) var cloak_volume_offset_db:   float = 0.0
@export_range(-30.0, 200.0, 0.1) var decloak_volume_offset_db:  float = 0.0

@export_group("Spatialization")
@export_range(0.0, 2.0, 0.05)    var distance_attenuation_strength: float = 0.25
@export_range(100.0, 5000.0, 50.0) var max_distance: float = 800.0
@export var no_distance_attenuation: bool = false
@export_range(1000.0, 20500.0, 100.0) var attenuation_filter_cutoff_hz: float = 12000.0

@export_group("Playback Duration")
## Wie lange der Sound mit voller Lautstärke spielen soll, BEVOR der Fade-Out
## einsetzt. Vollständig getrennt vom visuellen fade_in_duration in CloakData.
##
## Werte:
##   0.0 = Spiele den ganzen Sound bis zum Ende, dann Fade-Out (Default).
##         Nutzt die echte Stream-Länge als Wartezeit.
##   X   = Nach X Sekunden volle Lautstärke startet der Fade-Out — auch wenn
##         der Sound noch länger laufen würde. Sinnvoll für lange Cloak-Sounds
##         die früher ausklingen sollen, oder kurze Sounds die du verlängern
##         möchtest (über einen Loop in der AudioStream-Konfiguration).
##
## Beispiel "Star Trek BoP-Cloak": sound_play_duration=2.5, sound_fade_out_time=1.0
## → 2.5s voller Sound + 1.0s Ausklang = 3.5s gesamte Audio-Dauer.
## Komplett unabhängig davon ob fade_in_duration im CloakData 1.0s oder 5.0s ist.
@export_range(0.0, 30.0, 0.1) var sound_play_duration: float = 0.0

@export_group("Fade")
## Dauer des Fade-Outs am Ende der Wiedergabe. Beginnt nach sound_play_duration
## (bzw. nach Stream-Ende wenn play_duration=0).
@export_range(0.0, 5.0, 0.1) var sound_fade_out_time: float = 0.8
