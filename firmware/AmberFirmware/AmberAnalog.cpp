#include <Arduino.h>
#include "AmberAnalog.h"
#include "AmberComm.h"
#include "AmberCommands.h"

static bool handleReadPin(int size, byte *msg);
static bool handleWritePin(int size, byte *msg);

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
