#ifndef _WAVHDR_H_
#define _WAVHDR_H_

// -----------------------------------------------------------------------------
//  Header file for wave file header
// -----------------------------------------------------------------------------
#include<inttypes.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct wavHeader {
    /* RIFF Chunk Descriptor */
    uint8_t         RIFF[4];        // RIFF Header Magic header
    uint32_t        ChunkSize;      // RIFF Chunk Size
    uint8_t         WAVE[4];        // WAVE Header
    /* "fmt" sub-chunk */
    uint8_t         fmt[4];         // FMT header
    uint32_t        Subchunk1Size;  // Size of the fmt chunk
    uint16_t        AudioFormat;    // Audio format 1=PCM,6=mulaw,7=alaw,257=IBM Mu-Law, 258=IBM A-Law, 259=ADPCM
    uint16_t        NumOfChan;      // Number of channels 1=Mono 2=Stereo
    uint32_t        SamplesPerSec;  // Sampling Frequency in Hz
    uint32_t        bytesPerSec;    // bytes per second
    uint16_t        blockAlign;     // 2=16-bit mono, 4=16-bit stereo
    uint16_t        bitsPerSample;  // Number of bits per sample
    /* "data" sub-chunk */
    uint8_t         Subchunk2ID[4]; // "data"  string
    uint32_t        Subchunk2Size;  // Sampled data length
} wavHeader_t;

// Test wavfile compatibility
#define TEST_WAV_COMPAT(wav)  ( (wav)->AudioFormat==1 && ((wav)->NumOfChan==1 || (wav)->NumOfChan==2) && (wav)->SamplesPerSec==16000 && (wav)->bitsPerSample==16 && (wav)->Subchunk2ID[0]=='d' && (wav)->Subchunk2ID[3] == 'a' )
#define WAV_LEN(wav)          ( (wav)->Subchunk2Size )
#define WAV_NSAMPLES(wav)     ( WAV_LEN((wav))/ (((wav)->bitsPerSample/8)*(wav)->NumOfChan) )


#ifdef __cplusplus
} 
#endif

#endif
