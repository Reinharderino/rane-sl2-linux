# Rane SL2 en Linux

Soporte nativo para la interfaz DVS **Rane SL2** (`1cc5:0013`) en Linux, para
usarla con [Mixxx](https://mixxx.org) u otro software que hable ALSA.

El SL2 salió en 2009, Serato lo discontinuó, y sus drivers no funcionan en
macOS moderno ni cómodamente en Windows 10/11. El hardware está perfecto: son
cuatro entradas y cuatro salidas de 24 bits con previos de phono. Esto lo
devuelve a la vida.

## Qué es esto en realidad

**No es un driver nuevo.** Al mirar los descriptores USB del aparato resulta
que el SL2 ya es un dispositivo **USB Audio Class 2.0** casi de manual: sus
descriptores de clase son válidos y declara `bInterfaceProtocol =
UAC_VERSION_2`. Solo tiene dos rarezas que hacen que el kernel lo rechace:

1. Reporta clase de interfaz *vendor specific* (`0xFF`) en vez de audio.
2. Le falta el *interface association descriptor*, así que el kernel corta con
   `Audio class v2/v3 interfaces need an interface association`.

Además no responde a los pedidos estándar de frecuencia de muestreo (los
rechaza con *stall*), así que la tasa no se puede descubrir ni fijar: corre
siempre a **44100 Hz**.

Todo eso se resuelve con una entrada en la tabla de quirks de ALSA. Son unas
setenta líneas. El resto de este repositorio es el andamiaje para compilarla
en cualquier kernel y un diagnóstico para el hardware.

## Instalación

Requisitos: headers de tu kernel, `dkms`, `curl`, `make`, `python3` y
`alsa-utils`.

```bash
git clone <este-repo> && cd rane-sl2-linux
sudo ./install.sh
```

El instalador detecta tu kernel, **baja de kernel.org las fuentes de
`sound/usb` que corresponden a esa versión**, les aplica el quirk y compila el
módulo con DKMS. Se baja solo ese directorio, más o menos 1.4 MB, no el
tarball completo del kernel.

DKMS lo recompila solo en cada actualización de kernel.

Para volver atrás en cualquier momento:

```bash
sudo ./uninstall.sh
```

El `snd-usb-audio` original queda archivado por DKMS y vuelve intacto.

### Si tu distro compila el kernel con clang

CachyOS y algunas otras lo hacen. El instalador lo detecta leyendo
`/proc/version` y agrega `LLVM=1`. Si no lo hiciera, la compilación fallaría
con `unrecognized command-line option '-mstack-alignment=8'`.

### Secure Boot

DKMS firma el módulo con tu clave MOK si la tenés configurada. Si usás Secure
Boot y el módulo no carga, hay que inscribir esa clave (`mokutil --import`).

## El equipo no lo detecta

**Conectá el SL2 antes de encender la máquina.**

Muchos controladores xHCI no logran enumerarlo en caliente. El síntoma es el
LED parpadeando cinco veces y apagándose, y en `dmesg`:

```
usb 1-6: device descriptor read/64, error -110
usb usb1-port6: unable to enumerate USB device
```

No es un aparato roto ni un problema de cable: el SL2 tarda más en despertar
que lo que el host espera antes de rendirse. Conectado desde el arranque
enumera siempre y a la primera.

Si necesitás conectarlo con la máquina encendida, esperá unos diez segundos
después de enchufarlo y forzá un reinicio del puerto (ajustá la ruta a tu
puerto, sale del `dmesg`):

```bash
P=/sys/devices/pci0000:00/0000:00:14.0/usb1/1-0:1.0/usb1-port6
echo 1 | sudo tee $P/disable >/dev/null
echo 0 | sudo tee $P/disable >/dev/null
```

Para confirmar que enumeró: `lsusb | grep 1cc5`.

## Conexionado

| Elemento | Posición |
|---|---|
| Tornamesa | **PHONO** |
| Entrada del Rane | **PHONO** |
| Canal del mixer | **LINE** |
| Cables RCA | derechos: izquierda con izquierda |

El SL2 entrega **nivel de línea** por sus salidas; si ponés el canal del mixer
en phono le sumás otro previo de 40 dB y satura.

Si tu tornamesa tiene previo interno y la dejás en LINE, entonces la entrada
del Rane va en **CD**, no en PHONO. Lo que no puede pasar es mezclar los dos
criterios: dos previos en cadena saturan, y ninguno deja la señal 40 dB abajo.

## Configuración de Mixxx

En **Preferencias → Hardware de sonido**:

- API de sonido: **ALSA**
- Frecuencia de muestreo: **44100 Hz** — obligatorio. Con otra el dispositivo
  no abre, porque el driver declara 44100 y nada más.
- Buffer: empezá en 21 ms y bajá después

Salidas, con **mixer externo** (lo habitual con un SL2):

- `Plato 1` → Rane SL 2, canales **1-2**
- `Plato 2` → Rane SL 2, canales **3-4**
- `Principal`, `Auriculares` y `Cabina` sin asignar

El mixer hace la mezcla y el cue de auriculares. Dejá los faders y EQ de Mixxx
en posición neutra: las salidas de plato son post-fader y si no vas a estar
peleando contra dos controles para lo mismo.

Sin mixer externo, poné `Principal` en el SL2 canales 1-2. No mezcles el SL2
con `default` (PipeWire): son dos relojes distintos y vas a juntar cortes.

En **Control de vinilo**:

- Tipo de vinilo: **Serato CV02 Vinyl**
- Amplificación de señal: **0 dB**. Si necesitás subirla mucho, el problema
  está en el conexionado, no acá.
- `Control de vinilo 1` → canales 1-2, `Control de vinilo 2` → canales 3-4

## Diagnóstico

Si algo anda mal, cerrá Mixxx, dejá la púa apoyada con el disco girando y:

```bash
./sl2-signal-check
```

Mide nivel, recorte, frecuencia del tono de referencia y desfase entre
canales, y dice qué ajustar. Una señal sana se ve así:

```
Niveles
  CH1: pico  -19.9 dBFS   rms  -24.7 dBFS
  CH2: pico  -21.5 dBFS   rms  -26.5 dBFS

Tono de referencia  (Serato CV02 = 1000 Hz)
  CH1:   998.6 Hz     CH2:   998.6 Hz

Cuadratura  (los dos canales deben ir a 90 grados)
  desfase CH1-CH2: +91.2 grados   correcto
```

## Síntomas y causas

Estos cuatro cubren casi todo, y son difíciles de distinguir a ojo:

| Síntoma | Causa real |
|---|---|
| Círculo limpio pero el track no avanza | **Recorte.** El tono de referencia sobrevive a la saturación y sigue dibujando el círculo, pero el dato de posición va modulado en detalles finos de amplitud y se destruye. Bajá la ganancia. |
| El track va en reversa | Canales invertidos, o señal tan pobre que el sentido no se resuelve. Antes de cruzar cables, revisá los switches PHONO. |
| El track salta | Desfase de reloj. Si el tono de referencia lee ~1087 Hz en vez de 1000, el driver está declarando 48000 mientras el hardware corre a 44100: el módulo con el quirk no está activo. |
| Solo zumbido grave, casi sin nivel | Tornamesa en LINE con el Rane en PHONO, o la púa levantada. |

## Detalles técnicos

Descriptores del aparato:

| Interfaz | Clase | Endpoints | Rol |
|---|---|---|---|
| 0 | `0xFF` sub 1 | ninguno | control (`SL 2 Audio`) |
| 1 alt 1 | `0xFF` sub 2 | `0x06` OUT isoc, 112 B | reproducción |
| 2 alt 1 | `0xFF` sub 2 | `0x82` IN isoc, 112 B | captura |
| 3 | HID | `0x81` IN / `0x01` OUT interrupt | control y MIDI |

Formato: 4 canales, 24 bits en subslots de 4 bytes, 44100 Hz fijo,
`S32_LE` del lado de ALSA. El quirk usa `USB_DEVICE_VENDOR_SPEC` para hacer
match solo con las interfaces `0xFF`, de modo que la interfaz HID queda con
`usbhid` y no se la lleva el driver de audio.

Un detalle que sorprende al probar: **el ADC solo entrega datos con el stream
de salida activo**, porque el endpoint de entrada es la fuente de feedback
implícito del de salida. Si grabás con `arecord` solo, obtenés ceros digitales
exactos. Hay que reproducir algo en paralelo — es lo que hace
`sl2-signal-check`.

El PID `0x0014` es la variante que Serato Scratch Live reclama; `0x0013` es el
modo ASIO genérico, que es el que este quirk soporta. Si tenés una unidad que
se presenta como `0014`, abrí un issue: hace falta capturar sus descriptores.

## Licencia

El quirk se inserta en fuentes del kernel Linux y sigue su licencia,
**GPL-2.0**. Los scripts de este repositorio, lo mismo.

## Procedencia de los datos

Todo lo que hay en el quirk sale de los **descriptores que el propio aparato
publica** (`doc/lsusb-sl2.txt`, salida de `lsusb -v`) o de mediciones sobre la
señal. La frecuencia de 44100 Hz, por ejemplo, se determinó midiendo: el tono
de referencia de 1 kHz leía 1087 Hz al declarar 48000, y una captura
cronometrada de 10 s tardaba 10.9 s de reloj real.

Los drivers de Windows y macOS de Rane se consultaron para entender la
arquitectura del aparato — resultan ser envoltorios finos sobre los endpoints,
con toda la lógica en espacio de usuario — pero **ningún valor del quirk
proviene de desensamblarlos**, y esos binarios no se redistribuyen aquí porque
son propietarios de Rane/inMusic y Serato.

Si querés inspeccionarlos por tu cuenta, están dentro del instalador de
**Serato Scratch Live 2.5** (descarga gratuita con cuenta gratuita en
serato.com, en el archivo de versiones antiguas). Los drivers quedan en
`Serato/Drivers/<SO>/SL2/`, y el paquete ASIO se abre con `innoextract`.

## Otros modelos de la familia

El **SL3** y el **SL4** son de la misma generación y muy probablemente tengan
la misma estructura: interfaces vendor specific con descriptores UAC2 válidos
y sin IAD. Adaptar el quirk sería cuestión de cambiar el PID y ajustar
endpoints y número de canales.

Si tenés uno, abrí un issue con la salida de `lsusb -v -d 1cc5:XXXX` y con el
resultado de medir la frecuencia real. PIDs conocidos de la familia, sacados
de los archivos INF de Serato:

| Modelo | USB ID |
|---|---|
| Rane SL 1 | `13e5:0001` |
| Rane MP 4 | `13e5:0002` |
| Rane TTM 57SL | `13e5:8003` |
| Rane SL 3 | `1cc5:0003` |
| Rane Sixty-Eight | `1cc5:0005` |
| Rane Sixty Two | `1cc5:000a` |
| Rane SL 4 | `1cc5:0010` |
| Rane Sixty One | `1cc5:0012` |
| **Rane SL 2 (modo ASIO)** | **`1cc5:0013`** |
| Rane SL 2 (modo Scratch Live) | `1cc5:0014` |

## Envío al kernel

En `patch/` está el mismo quirk en formato de parche para el kernel Linux,
listo para mandar a la lista. Pasa `checkpatch.pl --strict` sin observaciones.

Si termina aceptándose upstream, este repositorio deja de hacer falta: el
soporte llega solo con el kernel de cualquier distribución.
