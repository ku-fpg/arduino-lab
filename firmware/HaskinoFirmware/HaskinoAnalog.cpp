#include <Arduino.h>
#include "HaskinoAnalog.h"
#include "HaskinoComm.h"
#include "HaskinoCommands.h"

static bool handleReadPin(int size, byte *msg);
static bool handleWritePin(int size, byte *msg);
static bool handleTonePin(int size, byte *msg);
static bool handleNoTonePin(int size, byte *msg);

bool parseAnalogMessage(int size, byte *msg)
    {
    switch (msg[0] ) 
        {
        case ALG_CMD_READ_PIN:
            return handleReadPin(size, msg);
            break;
        case ALG_CMD_WRITE_PIN:
            return handleWritePin(size, msg);
            break;
        case ALG_CMD_TONE_PIN:
            return handleTonePin(size, msg);
            break;
        case ALG_CMD_NOTONE_PIN:
            return handleNoTonePin(size, msg);
            break;
        }
    return false;
    }

static bool handleReadPin(int size, byte *msg)
    {
    byte pinNo = msg[1];
    uint16_t analogReply;

    analogReply = analogRead(pinNo);
    sendReply(sizeof(analogReply), ALG_RESP_READ_PIN, (byte *) &analogReply);
    return false;
    }

static bool handleWritePin(int size, byte *msg)
    {
    byte pinNo = msg[1];
    byte value = msg[2];

    analogWrite(pinNo, value);
    return false;
    }

static bool handleTonePin(int size, byte *msg)
    {
    byte pinNo = msg[1];
    unsigned int freq;
    memcpy(&freq, &msg[2], sizeof(unsigned int));
    unsigned long duration;
    memcpy(&duration, &msg[4], sizeof(unsigned long));

    if (duration == 0)
        {
        tone(pinNo, freq);
        }
    else
        {
        tone(pinNo, freq, duration);
        }
    return false;
    }

static bool handleNoTonePin(int size, byte *msg)
    {
    byte pinNo = msg[1];

    noTone(pinNo);
    return false;
    }


