# VOZ - A simple voice processing utility

**VOZ** is a set of three light CLI tools for linux with focus on devices with constrained resources.

The tools are:

- **voz-oww**: Detect __wakewords__ or __commandwords__ using openwakeword models.
- **voz-pre**: Simple audio processor based on webrct.
- **voz-ser**: Serial protocolo to integrate **voz-oww** or **voz-pre** with an audio frontend via UART.


This project is experimental and acepts only signed 16bit(LE) mono PCM audio at 16Khz.


## Sample Usages

Run the each command with ``--help`` to check out all avaiable options.

Wakeword detection:

Detect "Alexa" wakeword:

```bash
$ arecord -r 16000 -c 1 -f S16_LE -t raw - | ./voz-oww --output human --noiser=2 --preamp=2 --autogain=31 wwmodels/alexa_v0.1.tflite:alexa:0.55
```

Preprocess Audio:

```bash
$ cat audio.wav | ./voz-pre --ouput wav --noiser=4 --preamp=3 --autogain=30 > audio-out.wav
```

Serial backend:

```bash
$ 
```


**Note:**

The tools require loading of dynamic libs packed toghether with the tools. It could be required to use the env variable ``LD_LIBRARY_PATH`` to set
the path where the dynamic librare are. 


## Build

Clone this repository.

**Dependencies:**

A custom script builds required dynamic libraries. The build require a x86 host with bash,docker and wget. To complile the dependecies
symply call the build helper script provided:

```bash
$ cd voz
$ ./deps.sh
```

**Tools:**

To build the tools Zig 0.11 is required. To build the tools the usual zig build prompt can be used:

```bash
$ zig build
```

At the moment three archs are supported: am64, arm64 and armv7-a (with hf and NEON) for gnu abi.




