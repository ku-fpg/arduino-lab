-------------------------------------------------------------------------------
-- |
-- Module      :  System.Hardware.Haskino.Data
--                Based on System.Hardware.Arduino.Data
-- Copyright   :  (c) University of Kansas
--                System.Hardware.Arduino (c) Levent Erkok
-- License     :  BSD3
-- Stability   :  experimental
--
-- Underlying data structures
-------------------------------------------------------------------------------
{-# LANGUAGE FlexibleInstances, GADTs, KindSignatures, RankNTypes,
             OverloadedStrings, ScopedTypeVariables, StandaloneDeriving,
             GeneralizedNewtypeDeriving, NamedFieldPuns, DataKinds #-}

module System.Hardware.Haskino.Data where

import           Control.Applicative
import           Control.Concurrent (Chan, MVar, ThreadId, withMVar, modifyMVar, 
                                     modifyMVar_, putMVar, takeMVar, readMVar,
                                     newEmptyMVar)
import           Control.Monad (ap, liftM2, when, unless, void)
import           Control.Monad.Trans

import           Data.Bits ((.|.), (.&.), setBit)
import           Data.List (intercalate)
import qualified Data.Map as M
import           Data.Maybe (listToMaybe)
import qualified Data.Set as S
import           Data.Monoid
import           Data.Word (Word8, Word16, Word32)

import           System.Hardware.Serialport (SerialPort)

import           System.Hardware.Haskino.Expr
import           System.Hardware.Haskino.Utils

import Debug.Trace
-----------------------------------------------------------------------------

data Arduino :: * -> * where
    Control        :: Control                         -> Arduino ()
    Command        :: Command                         -> Arduino ()
    Local          :: Local a                         -> Arduino a
    Procedure      :: Procedure a                     -> Arduino a
    RemoteBinding  :: RemoteBinding a                 -> Arduino a
    LiftIO         :: IO a                            -> Arduino a
    Bind           :: Arduino a -> (a -> Arduino b)   -> Arduino b
    Return         :: a                               -> Arduino a

instance Monad Arduino where
        return = Return
        (>>=) = Bind

instance Applicative Arduino where
  pure  = return
  (<*>) = ap

instance Functor Arduino where
  fmap f c = c >>= return . f

instance Monoid a => Monoid (Arduino a) where
  mappend = liftM2 mappend
  mempty  = return mempty

instance MonadIO Arduino where
  liftIO m = LiftIO m

type Pin  = Word8
type PinE = Expr Word8

-- | Bailing out: print the given string on stdout and die
runDie :: ArduinoConnection -> String -> [String] -> IO a
runDie c m ms = do 
    let f = bailOut c
    f m ms

-- Given a pin number, this function determines which port it belongs to
pinNoPortNo :: Pin -> Word8
pinNoPortNo n = n `quot` 8

-- | On the Arduino, pins are grouped into banks of 8.
-- Given a pin, this function determines which index it belongs to in its port
pinPortIndex :: Pin -> Word8
pinPortIndex p = p `rem` 8

-- | The mode for a pin.
data PinMode = INPUT
             | OUTPUT
             | INPUT_PULLUP
        deriving (Eq, Show, Enum)

-- | LCD's connected to the board
data LCD = LCD {
                 lcdController     :: LCDController -- ^ Actual controller
               , lcdState          :: MVar LCDData  -- ^ State information    
               }

-- | Hitachi LCD controller: See: <http://en.wikipedia.org/wiki/Hitachi_HD44780_LCD_controller>.
-- We model only the 4-bit variant, with RS and EN lines only. (The most common Arduino usage.)
-- The data sheet can be seen at: <http://lcd-linux.sourceforge.net/pdfdocs/hd44780.pdf>.
data LCDController = 
    Hitachi44780 {
                       lcdRS       :: Pin  -- ^ Hitachi pin @ 4@: Register-select
                     , lcdEN       :: Pin  -- ^ Hitachi pin @ 6@: Enable
                     , lcdD4       :: Pin  -- ^ Hitachi pin @11@: Data line @4@
                     , lcdD5       :: Pin  -- ^ Hitachi pin @12@: Data line @5@
                     , lcdD6       :: Pin  -- ^ Hitachi pin @13@: Data line @6@
                     , lcdD7       :: Pin  -- ^ Hitachi pin @14@: Data line @7@
                     , lcdBL       :: Maybe Pin -- ^ Backlight control pin (if present)
                     , lcdRows     :: Int  -- ^ Number of rows (typically 1 or 2, upto 4)
                     , lcdCols     :: Int  -- ^ Number of cols (typically 16 or 20, upto 40)
                     , dotMode5x10 :: Bool -- ^ Set to True if 5x10 dots are used
                     }
    | I2CHitachi44780 {
                       address     :: Word8 -- ^ I2C Slave Address of LCD
                     , lcdRows     :: Int  -- ^ Number of rows (typically 1 or 2, upto 4)
                     , lcdCols     :: Int  -- ^ Number of cols (typically 16 or 20, upto 40)
                     , dotMode5x10 :: Bool -- ^ Set to True if 5x10 dots are used
                     }
                     deriving Show

-- | State of the LCD, a mere 8-bit word for the Hitachi
data LCDData = LCDData {
                  lcdDisplayMode    :: Word8         -- ^ Display mode (left/right/scrolling etc.)
                , lcdDisplayControl :: Word8         -- ^ Display control (blink on/off, display on/off etc.)
                , lcdGlyphCount     :: Word8         -- ^ Count of custom created glyphs (typically at most 8)
                , lcdBacklightState :: Bool
                }

-- | State of the connection
data ArduinoConnection = ArduinoConnection {
                message       :: String -> IO ()                      -- ^ Current debugging routine
              , bailOut       :: forall a. String -> [String] -> IO a -- ^ Clean-up and quit with a hopefully informative message
              , port          :: SerialPort                           -- ^ Serial port we are communicating on
              , firmwareID    :: String                               -- ^ The ID of the board (as identified by the Board itself)
              , deviceChannel :: Chan Response                        -- ^ Incoming messages from the board
              , processor     :: Processor                            -- ^ Type of processor on board
              , listenerTid   :: MVar ThreadId                        -- ^ ThreadId of the listener
              , refIndex      :: MVar Int                             -- ^ Index used for remote references
              }

type SlaveAddress = Word8
type SlaveAddressE = Expr Word8
type MinPulse = Word16
type MaxPulse = Word16
type TaskLength = Word16
type TaskID = Word8
type TaskIDE = Expr Word8
type TimeMillis = Word32
type TimeMillisE = Expr Word32
type TimeMicros = Word32
type TimeMicrosE = Expr Word32
type TaskPos = Word16
type VarSize = Word8
-- ToDo: Readd Stepper types

data Command =
       SystemReset                              -- ^ Send system reset
     | SetPinModeE PinE PinMode                 -- ^ Set the mode on a pin
--  ToDo: PinMode expression?
     | DigitalPortWriteE PinE (Expr Word8) (Expr Word8)
     | DigitalWriteE PinE (Expr Bool)              
     | AnalogWriteE PinE (Expr Word16)
     | ToneE PinE (Expr Word16) (Maybe (Expr Word32))       -- ^ Play a tone on a pin
     | NoToneE PinE                             -- ^ Stop playing a tone on a pin
     | I2CWrite SlaveAddressE (Expr [Word8])
     | I2CConfig
     | CreateTaskE TaskIDE (Arduino ())
     | DeleteTaskE TaskIDE
     | ScheduleTaskE TaskIDE TimeMillisE
     | BootTaskE TaskIDE
     | ScheduleReset
     | WriteRemoteRefB (RemoteRef Bool) (Expr Bool)
     | WriteRemoteRef8 (RemoteRef Word8) (Expr Word8)
     | WriteRemoteRef16 (RemoteRef Word16) (Expr Word16)
     | WriteRemoteRef32 (RemoteRef Word32) (Expr Word32)
     | WriteRemoteRefL8 (RemoteRef [Word8]) (Expr [Word8])
     | ModifyRemoteRefB (RemoteRef Bool) (Expr Bool -> Expr Bool)
     | ModifyRemoteRef8 (RemoteRef Word8) (Expr Word8 -> Expr Word8)
     | ModifyRemoteRef16 (RemoteRef Word16) (Expr Word16 -> Expr Word16)
     | ModifyRemoteRef32 (RemoteRef Word32) (Expr Word32 -> Expr Word32)
     | ModifyRemoteRefL8 (RemoteRef [Word8]) (Expr [Word8] -> Expr [Word8])
     | WhileRemoteRefB (RemoteRef Bool) (Expr Bool -> Expr Bool) (Expr Bool -> Expr Bool) (Arduino ())
     | WhileRemoteRef8 (RemoteRef Word8) (Expr Word8 -> Expr Bool) (Expr Word8 -> Expr Word8) (Arduino ())
     | WhileRemoteRef16 (RemoteRef Word16) (Expr Word16 -> Expr Bool) (Expr Word16 -> Expr Word16) (Arduino ())
     | WhileRemoteRef32 (RemoteRef Word32) (Expr Word32 -> Expr Bool) (Expr Word32 -> Expr Word32) (Arduino ())
     | WhileRemoteRefL8 (RemoteRef [Word8]) (Expr [Word8] -> Expr Bool) (Expr [Word8] -> Expr [Word8]) (Arduino ())
     | LoopE (Arduino ())
     | ForInE (Expr [Word8]) (Expr Word8 -> Arduino ()) 
     | IfThenElse (Expr Bool) (Arduino ()) (Arduino ())
     -- ToDo: add one wire and encoder procedures, readd stepper and servo

systemReset :: Arduino ()
systemReset = Command SystemReset

setPinMode :: Pin -> PinMode -> Arduino ()
setPinMode p pm = Command $ SetPinModeE (lit p) pm

setPinModeE :: PinE -> PinMode -> Arduino ()
setPinModeE p pm = Command $ SetPinModeE p pm

digitalWrite :: Pin -> Bool -> Arduino ()
digitalWrite p b = Command $ DigitalWriteE (lit p) (lit b)

digitalWriteE :: PinE -> Expr Bool -> Arduino ()
digitalWriteE p b = Command $ DigitalWriteE p b

digitalPortWrite :: Pin -> Word8 -> Word8 -> Arduino ()
digitalPortWrite p b m = Command $ DigitalPortWriteE (lit p) (lit b) (lit m)

digitalPortWriteE :: PinE -> Expr Word8 -> Expr Word8 -> Arduino ()
digitalPortWriteE p b m = Command $ DigitalPortWriteE p b m

analogWrite :: Pin -> Word16 -> Arduino ()
analogWrite p w = Command $ AnalogWriteE (lit p) (lit w)

analogWriteE :: PinE -> Expr Word16 -> Arduino ()
analogWriteE p w = Command $ AnalogWriteE p w

tone :: Pin -> Word16 -> Maybe Word32 -> Arduino ()
tone p f Nothing = Command $ ToneE (lit p) (lit f) Nothing
tone p f (Just d) = Command $ ToneE (lit p) (lit f) (Just $ lit d)

toneE :: PinE -> Expr Word16 -> Maybe (Expr Word32) -> Arduino ()
toneE p f d = Command $ ToneE p f d

noTone :: Pin -> Arduino ()
noTone p = Command $ NoToneE (lit p)

noToneE :: PinE -> Arduino ()
noToneE p = Command $ NoToneE p

i2cWrite :: SlaveAddress -> [Word8] -> Arduino ()
i2cWrite sa ws = Command $ I2CWrite (lit sa) (lit ws)

i2cWriteE :: SlaveAddressE -> Expr [Word8] -> Arduino ()
i2cWriteE sa ws = Command $ I2CWrite sa ws

i2cConfig :: Arduino ()
i2cConfig = Command $ I2CConfig

createTask :: TaskID -> Arduino () -> Arduino ()
createTask tid ps = Command $ CreateTaskE (lit tid) ps

createTaskE :: TaskIDE -> Arduino () -> Arduino ()
createTaskE tid ps = Command  $ CreateTaskE tid ps

deleteTask :: TaskID -> Arduino ()
deleteTask tid = Command $ DeleteTaskE (lit tid)

deleteTaskE :: TaskIDE -> Arduino ()
deleteTaskE tid = Command $ DeleteTaskE tid

scheduleTask :: TaskID -> TimeMillis -> Arduino ()
scheduleTask tid tt = Command $ ScheduleTaskE (lit tid) (lit tt)

scheduleTaskE :: TaskIDE -> TimeMillisE -> Arduino ()
scheduleTaskE tid tt = Command $ ScheduleTaskE tid tt

scheduleReset :: Arduino ()
scheduleReset = Command ScheduleReset

bootTaskE :: TaskIDE -> Arduino ()
bootTaskE tid = Command $ BootTaskE tid

loopE :: Arduino () -> Arduino()
loopE ps = Command $ LoopE ps

forInE :: Expr [Word8] -> (Expr Word8 -> Arduino ()) -> Arduino ()
forInE ws f = Command $ ForInE ws f

ifThenElse :: Expr Bool -> Arduino () -> Arduino() -> Arduino()
ifThenElse be tps eps = Command $ IfThenElse be tps eps

writeRemoteRefB :: RemoteRef Bool -> Expr Bool -> Arduino ()
writeRemoteRefB r e = Command $ WriteRemoteRefB r e

writeRemoteRef8 :: RemoteRef Word8 -> Expr Word8 -> Arduino ()
writeRemoteRef8 r e = Command $ WriteRemoteRef8 r e

writeRemoteRef16 :: RemoteRef Word16 -> Expr Word16 -> Arduino ()
writeRemoteRef16 r e = Command $ WriteRemoteRef16 r e

writeRemoteRef32 :: RemoteRef Word32 -> Expr Word32 -> Arduino ()
writeRemoteRef32 r e = Command $ WriteRemoteRef32 r e

writeRemoteRefL8 :: RemoteRef [Word8] -> Expr [Word8] -> Arduino ()
writeRemoteRefL8 r e = Command $ WriteRemoteRefL8 r e

modifyRemoteRefB :: RemoteRef Bool -> (Expr Bool -> Expr Bool) -> Arduino ()
modifyRemoteRefB r f = Command $ ModifyRemoteRefB r f

modifyRemoteRef8 :: RemoteRef Word8 -> (Expr Word8 -> Expr Word8) -> Arduino ()
modifyRemoteRef8 r f = Command $ ModifyRemoteRef8 r f

modifyRemoteRef16 :: RemoteRef Word16 -> (Expr Word16 -> Expr Word16) -> Arduino ()
modifyRemoteRef16 r f = Command $ ModifyRemoteRef16 r f

modifyRemoteRef32 :: RemoteRef Word32 -> (Expr Word32 -> Expr Word32) -> Arduino ()
modifyRemoteRef32 r f = Command $ ModifyRemoteRef32 r f

modifyRemoteRefL8 :: RemoteRef [Word8] -> (Expr [Word8] -> Expr [Word8]) -> Arduino ()
modifyRemoteRefL8 r f = Command $ ModifyRemoteRefL8 r f

whileRemoteRefB :: RemoteRef Bool -> (Expr Bool -> Expr Bool) -> (Expr Bool -> Expr Bool) -> Arduino () -> Arduino ()
whileRemoteRefB r bf uf cb  = Command $ WhileRemoteRefB r bf uf cb

whileRemoteRef8 :: RemoteRef Word8 -> (Expr Word8 -> Expr Bool) -> (Expr Word8 -> Expr Word8) -> Arduino () -> Arduino ()
whileRemoteRef8 r bf uf cb = Command $ WhileRemoteRef8 r bf uf cb

whileRemoteRef16 :: RemoteRef Word16 -> (Expr Word16 -> Expr Bool) -> (Expr Word16 -> Expr Word16) -> Arduino () -> Arduino ()
whileRemoteRef16 r bf uf cb = Command $ WhileRemoteRef16 r bf uf cb

whileRemoteRef32 :: RemoteRef Word32 -> (Expr Word32 -> Expr Bool) -> (Expr Word32 -> Expr Word32) -> Arduino () -> Arduino ()
whileRemoteRef32 r bf uf cb = Command $ WhileRemoteRef32 r bf uf cb

whileRemoteRefL8 :: RemoteRef [Word8] -> (Expr [Word8] -> Expr Bool) -> (Expr [Word8] -> Expr [Word8]) -> Arduino () -> Arduino ()
whileRemoteRefL8 r bf uf cb = Command $ WhileRemoteRefL8 r bf uf cb

-- ToDo: Readd servo and stepper functions

class RemoteReference a where
    newRemoteRef          :: Expr a -> Arduino (RemoteRef a)
    readRemoteRef         :: RemoteRef a -> Arduino (Expr a)
    writeRemoteRef        :: RemoteRef a -> Expr a -> Arduino ()
    modifyRemoteRef       :: RemoteRef a -> (Expr a -> Expr a) -> 
                             Arduino ()
    while                 :: RemoteRef a -> (Expr a -> Expr Bool) -> 
                             (Expr a -> Expr a) -> Arduino () -> Arduino ()

instance RemoteReference Bool where
    newRemoteRef = newRemoteRefB
    readRemoteRef = readRemoteRefB
    writeRemoteRef = writeRemoteRefB
    modifyRemoteRef = modifyRemoteRefB
    while = whileRemoteRefB

instance RemoteReference Word8 where
    newRemoteRef = newRemoteRef8
    readRemoteRef = readRemoteRef8
    writeRemoteRef = writeRemoteRef8
    modifyRemoteRef = modifyRemoteRef8
    while = whileRemoteRef8

instance RemoteReference Word16 where
    newRemoteRef = newRemoteRef16
    readRemoteRef = readRemoteRef16
    writeRemoteRef = writeRemoteRef16
    modifyRemoteRef = modifyRemoteRef16
    while = whileRemoteRef16

instance RemoteReference Word32 where
    newRemoteRef = newRemoteRef32
    readRemoteRef = readRemoteRef32
    writeRemoteRef = writeRemoteRef32
    modifyRemoteRef = modifyRemoteRef32
    while = whileRemoteRef32

instance RemoteReference [Word8] where
    newRemoteRef = newRemoteRefL8
    readRemoteRef = readRemoteRefL8
    writeRemoteRef = writeRemoteRefL8
    modifyRemoteRef = modifyRemoteRefL8
    while = whileRemoteRefL8

data Control =
      Loop (Arduino ())

loop :: Arduino () -> Arduino ()
loop ps = Control $ Loop ps

data Local :: * -> * where
     Debug            :: String -> Local ()
     Die              :: String -> [String] -> Local ()

deriving instance Show a => Show (Local a)

debug :: String -> Arduino ()
debug msg = Local $ Debug msg

die :: String -> [String] -> Arduino ()
die msg msgs = Local $ Die msg msgs

data Procedure :: * -> * where
     QueryFirmware  :: Procedure Word16                   -- ^ Query the Firmware version installed
     QueryFirmwareE :: Procedure (Expr Word16)                  -- ^ Query the Firmware version installed
     QueryProcessor :: Procedure Processor                -- ^ Query the type of processor on 
-- ToDo: E version of QueryProcessor, handle Expr Processor
     Micros         :: Procedure Word32
     MicrosE        :: Procedure (Expr Word32)
     Millis         :: Procedure Word32
     MillisE        :: Procedure (Expr Word32)
     DelayMillis    :: TimeMillis -> Procedure ()
     DelayMicros    :: TimeMicros -> Procedure ()
     DelayMillisE   :: TimeMillisE -> Procedure ()
     DelayMicrosE   :: TimeMicrosE -> Procedure ()
     DigitalRead    :: Pin -> Procedure Bool            -- ^ Read the avlue ona pin digitally
     DigitalReadE   :: PinE -> Procedure (Expr Bool)         -- ^ Read the avlue ona pin digitally
     DigitalPortRead  :: Pin -> Word8 -> Procedure Word8          -- ^ Read the values on a port digitally
     DigitalPortReadE :: PinE -> Expr Word8 -> Procedure (Expr Word8)
     AnalogRead     :: Pin -> Procedure Word16          -- ^ Read the analog value on a pin
     AnalogReadE    :: PinE -> Procedure (Expr Word16)          
     I2CRead :: SlaveAddress -> Word8 -> Procedure [Word8]
     I2CReadE :: SlaveAddressE -> Expr Word8 -> Procedure (Expr [Word8])
     QueryAllTasks  :: Procedure [TaskID]
     QueryAllTasksE :: Procedure (Expr [TaskID])
     QueryTask  :: TaskID -> Procedure (Maybe (TaskLength, TaskLength, TaskPos, TimeMillis))
     QueryTaskE :: TaskIDE -> Procedure (Maybe (TaskLength, TaskLength, TaskPos, TimeMillis))
     -- Todo: add one wire queries, readd pulse?
     ReadRemoteRefB  :: RemoteRef Bool   -> Procedure (Expr Bool)
     ReadRemoteRef8  :: RemoteRef Word8  -> Procedure (Expr Word8)
     ReadRemoteRef16 :: RemoteRef Word16 -> Procedure (Expr Word16)
     ReadRemoteRef32 :: RemoteRef Word32 -> Procedure (Expr Word32)
     ReadRemoteRefL8 :: RemoteRef [Word8] -> Procedure (Expr [Word8])

deriving instance Show a => Show (Procedure a)

queryFirmware :: Arduino Word16
queryFirmware = Procedure QueryFirmware

queryFirmwareE :: Arduino (Expr Word16)
queryFirmwareE = Procedure QueryFirmwareE

queryProcessor :: Arduino Processor
queryProcessor = Procedure QueryProcessor

micros :: Arduino Word32
micros = Procedure Micros

microsE :: Arduino (Expr Word32)
microsE = Procedure MicrosE

millis :: Arduino Word32
millis = Procedure Millis

millisE :: Arduino (Expr Word32)
millisE = Procedure MillisE

delayMillis :: TimeMillis -> Arduino ()
delayMillis t = Procedure $ DelayMillis t

delayMillisE :: TimeMillisE -> Arduino ()
delayMillisE t = Procedure $ DelayMillisE t

delayMicros :: TimeMicros -> Arduino ()
delayMicros t = Procedure $ DelayMicros t

delayMicrosE :: TimeMicrosE -> Arduino ()
delayMicrosE t = Procedure $ DelayMicrosE t

-- ToDo: Do some sort of analog mapping locally?

-- digitalPortRead :: Port -> Arduino Word8
-- digitalPortRead p = Procedure $ DigitalPortRead p

-- digitalPortReadE :: Port -> Arduino (Expr Word8)
-- digitalPortReadE p = Procedure $ DigitalPortReadE p

digitalRead :: Pin -> Arduino Bool
digitalRead p = Procedure $ DigitalRead p

digitalReadE :: PinE -> Arduino (Expr Bool)
digitalReadE p = Procedure $ DigitalReadE p

digitalPortRead :: Pin -> Word8 -> Arduino Word8
digitalPortRead p m = Procedure $ DigitalPortRead p m

digitalPortReadE :: PinE -> Expr Word8 -> Arduino (Expr Word8)
digitalPortReadE p m = Procedure $ DigitalPortReadE p m

analogRead :: Pin -> Arduino Word16
analogRead p = Procedure $ AnalogRead p

analogReadE :: PinE -> Arduino (Expr Word16)
analogReadE p = Procedure $ AnalogReadE p

i2cRead :: SlaveAddress -> Word8 -> Arduino [Word8]
i2cRead sa cnt = Procedure $ I2CRead sa cnt

i2cReadE :: SlaveAddressE -> Expr Word8 -> Arduino (Expr [Word8])
i2cReadE sa cnt = Procedure $ I2CReadE sa cnt

queryAllTasks :: Arduino [TaskID]
queryAllTasks = Procedure QueryAllTasks

queryAllTasksE :: Arduino (Expr [TaskID])
queryAllTasksE = Procedure QueryAllTasksE

queryTask :: TaskID -> Arduino (Maybe (TaskLength, TaskLength, TaskPos, TimeMillis))
queryTask tid = Procedure $ QueryTask tid

queryTaskE :: TaskIDE -> Arduino (Maybe (TaskLength, TaskLength, TaskPos, TimeMillis))
queryTaskE tid = Procedure $ QueryTaskE tid

readRemoteRefB :: RemoteRef Bool -> Arduino (Expr Bool)
readRemoteRefB n = Procedure $ ReadRemoteRefB n

readRemoteRef8 :: RemoteRef Word8 -> Arduino (Expr Word8)
readRemoteRef8 n = Procedure $ ReadRemoteRef8 n

readRemoteRef16 :: RemoteRef Word16 -> Arduino (Expr Word16)
readRemoteRef16 n = Procedure $ ReadRemoteRef16 n

readRemoteRef32 :: RemoteRef Word32 -> Arduino (Expr Word32)
readRemoteRef32 n = Procedure $ ReadRemoteRef32 n

readRemoteRefL8 :: RemoteRef [Word8] -> Arduino (Expr [Word8])
readRemoteRefL8 n = Procedure $ ReadRemoteRefL8 n

data RemoteBinding :: * -> * where
     NewRemoteRefB    :: Expr Bool   -> RemoteBinding (RemoteRef Bool)
     NewRemoteRef8    :: Expr Word8  -> RemoteBinding (RemoteRef Word8)
     NewRemoteRef16   :: Expr Word16 -> RemoteBinding (RemoteRef Word16)
     NewRemoteRef32   :: Expr Word32 -> RemoteBinding (RemoteRef Word32)
     NewRemoteRefL8   :: Expr [Word8] -> RemoteBinding (RemoteRef [Word8])

newRemoteRefB :: Expr Bool -> Arduino (RemoteRef Bool)
newRemoteRefB n = RemoteBinding $ NewRemoteRefB n

newRemoteRef8 :: Expr Word8 -> Arduino (RemoteRef Word8)
newRemoteRef8 n = RemoteBinding $ NewRemoteRef8 n

newRemoteRef16 :: Expr Word16 -> Arduino (RemoteRef Word16)
newRemoteRef16 n = RemoteBinding $ NewRemoteRef16 n

newRemoteRef32 :: Expr Word32 -> Arduino (RemoteRef Word32)
newRemoteRef32 n = RemoteBinding $ NewRemoteRef32 n

newRemoteRefL8 :: Expr [Word8] -> Arduino (RemoteRef [Word8])
newRemoteRefL8 n = RemoteBinding $ NewRemoteRefL8 n

-- | A response, as returned from the Arduino
data Response = DelayResp
              | Firmware Word16                      -- ^ Firmware version (maj/min)
              | ProcessorType Word8                  -- ^ Processor report
              | MicrosReply Word32                   -- ^ Elapsed Microseconds
              | MillisReply Word32                   -- ^ Elapsed Milliseconds
              | DigitalReply Word8                   -- ^ Status of a pin
              | DigitalPortReply Word8               -- ^ Status of a port
              | AnalogReply Word16                   -- ^ Status of an analog pin
              | StringMessage  String                -- ^ String message from Firmware
              | I2CReply [Word8]                     -- ^ Response to a I2C Read
              | QueryAllTasksReply [Word8]           -- ^ Response to Query All Tasks
              | QueryTaskReply (Maybe (TaskLength, TaskLength, TaskPos, TimeMillis))
              | NewReply Word8
              | ReadRefBReply Bool
              | ReadRef8Reply Word8
              | ReadRef16Reply Word16
              | ReadRef32Reply Word32
              | ReadRefL8Reply [Word8]
              | FailedNewRef
              | Unimplemented (Maybe String) [Word8] -- ^ Represents messages currently unsupported
              | EmptyFrame
              | InvalidChecksumFrame [Word8]
    deriving Show

-- | Haskino Firmware commands, see: 
-- | https://github.com/ku-fpg/haskino/wiki/Haskino-Firmware-Protocol-Definition
data FirmwareCmd = BC_CMD_SYSTEM_RESET
                 | BC_CMD_SET_PIN_MODE
                 | BC_CMD_DELAY_MILLIS
                 | BC_CMD_DELAY_MICROS
                 | BC_CMD_LOOP
                 | BC_CMD_WHILE
                 | BC_CMD_IF_THEN_ELSE
                 | BC_CMD_FORIN
                 | BS_CMD_REQUEST_VERSION
                 | BS_CMD_REQUEST_TYPE
                 | BS_CMD_REQUEST_MICROS
                 | BS_CMD_REQUEST_MILLIS
                 | DIG_CMD_READ_PIN
                 | DIG_CMD_WRITE_PIN
                 | DIG_CMD_READ_PORT
                 | DIG_CMD_WRITE_PORT
                 | ALG_CMD_READ_PIN
                 | ALG_CMD_WRITE_PIN
                 | ALG_CMD_TONE_PIN
                 | ALG_CMD_NOTONE_PIN
                 | I2C_CMD_CONFIG
                 | I2C_CMD_READ
                 | I2C_CMD_WRITE
                 | SCHED_CMD_CREATE_TASK
                 | SCHED_CMD_DELETE_TASK
                 | SCHED_CMD_ADD_TO_TASK
                 | SCHED_CMD_SCHED_TASK
                 | SCHED_CMD_QUERY_ALL
                 | SCHED_CMD_QUERY
                 | SCHED_CMD_RESET
                 | SCHED_CMD_BOOT_TASK
                 | REF_CMD_NEW
                 | REF_CMD_READ
                 | REF_CMD_WRITE
                deriving Show

-- | Compute the numeric value of a command
firmwareCmdVal :: FirmwareCmd -> Word8
firmwareCmdVal BC_CMD_SYSTEM_RESET      = 0x10
firmwareCmdVal BC_CMD_SET_PIN_MODE      = 0x11
firmwareCmdVal BC_CMD_DELAY_MILLIS      = 0x12
firmwareCmdVal BC_CMD_DELAY_MICROS      = 0x13
firmwareCmdVal BC_CMD_WHILE             = 0x14
firmwareCmdVal BC_CMD_IF_THEN_ELSE      = 0x15
firmwareCmdVal BC_CMD_LOOP              = 0x16
firmwareCmdVal BC_CMD_FORIN             = 0x17
firmwareCmdVal BS_CMD_REQUEST_VERSION   = 0x20
firmwareCmdVal BS_CMD_REQUEST_TYPE      = 0x21
firmwareCmdVal BS_CMD_REQUEST_MILLIS    = 0x22
firmwareCmdVal BS_CMD_REQUEST_MICROS    = 0x23
firmwareCmdVal DIG_CMD_READ_PIN         = 0x30
firmwareCmdVal DIG_CMD_WRITE_PIN        = 0x31
firmwareCmdVal DIG_CMD_READ_PORT        = 0x32
firmwareCmdVal DIG_CMD_WRITE_PORT       = 0x33
firmwareCmdVal ALG_CMD_READ_PIN         = 0x40
firmwareCmdVal ALG_CMD_WRITE_PIN        = 0x41
firmwareCmdVal ALG_CMD_TONE_PIN         = 0x42
firmwareCmdVal ALG_CMD_NOTONE_PIN       = 0x43
firmwareCmdVal I2C_CMD_CONFIG           = 0x50
firmwareCmdVal I2C_CMD_READ             = 0x51
firmwareCmdVal I2C_CMD_WRITE            = 0x52
firmwareCmdVal SCHED_CMD_CREATE_TASK    = 0xA0
firmwareCmdVal SCHED_CMD_DELETE_TASK    = 0xA1
firmwareCmdVal SCHED_CMD_ADD_TO_TASK    = 0xA2
firmwareCmdVal SCHED_CMD_SCHED_TASK     = 0xA3
firmwareCmdVal SCHED_CMD_QUERY          = 0xA4
firmwareCmdVal SCHED_CMD_QUERY_ALL      = 0xA5
firmwareCmdVal SCHED_CMD_RESET          = 0xA6
firmwareCmdVal SCHED_CMD_BOOT_TASK      = 0xA7
firmwareCmdVal REF_CMD_NEW              = 0xB0
firmwareCmdVal REF_CMD_READ             = 0xB1
firmwareCmdVal REF_CMD_WRITE            = 0xB2

data RefType = REF_BOOL
             | REF_WORD8
             | REF_WORD16
             | REF_WORD32
             | REF_LIST8
            deriving Show

-- | Compute the numeric value of a reference type
refTypeCmdVal :: RefType -> Word8
refTypeCmdVal REF_BOOL                  = 0x00
refTypeCmdVal REF_WORD8                 = 0x01
refTypeCmdVal REF_WORD16                = 0x02
refTypeCmdVal REF_WORD32                = 0x03
refTypeCmdVal REF_LIST8                 = 0x04

-- | Firmware replies, see: 
-- | https://github.com/ku-fpg/haskino/wiki/Haskino-Firmware-Protocol-Definition
data FirmwareReply =  BC_RESP_DELAY
                   |  BS_RESP_VERSION
                   |  BS_RESP_TYPE
                   |  BS_RESP_MICROS
                   |  BS_RESP_MILLIS
                   |  BS_RESP_STRING
                   |  DIG_RESP_READ_PIN
                   |  DIG_RESP_READ_PORT
                   |  ALG_RESP_READ_PIN
                   |  I2C_RESP_READ
                   |  SCHED_RESP_QUERY
                   |  SCHED_RESP_QUERY_ALL
                   |  REF_RESP_NEW
                   |  REF_RESP_READ
                deriving Show

getFirmwareReply :: Word8 -> Either Word8 FirmwareReply
getFirmwareReply 0x18 = Right BC_RESP_DELAY
getFirmwareReply 0x28 = Right BS_RESP_VERSION
getFirmwareReply 0x29 = Right BS_RESP_TYPE
getFirmwareReply 0x2A = Right BS_RESP_MICROS
getFirmwareReply 0x2B = Right BS_RESP_MILLIS
getFirmwareReply 0x2C = Right BS_RESP_STRING
getFirmwareReply 0x38 = Right DIG_RESP_READ_PIN
getFirmwareReply 0x39 = Right DIG_RESP_READ_PORT
getFirmwareReply 0x48 = Right ALG_RESP_READ_PIN
getFirmwareReply 0x58 = Right I2C_RESP_READ
getFirmwareReply 0xA8 = Right SCHED_RESP_QUERY
getFirmwareReply 0xA9 = Right SCHED_RESP_QUERY_ALL
getFirmwareReply 0xB8 = Right REF_RESP_NEW
getFirmwareReply 0xB9 = Right REF_RESP_READ
getFirmwareReply n    = Left n

--stepDelayVal :: StepDelay -> Word8
--stepDelayVal OneUs = 0x00
--stepDelayVal TwoUs = 0x08

--stepDirVal :: StepDir -> Word8
--stepDirVal CW = 0x00
--stepDirVal CCW = 0x01

data Processor = ATMEGA8
               | ATMEGA168
               | ATMEGA328P
               | ATMEGA1280
               | ATMEGA256
               | ATMEGA32U4
               | ATMEGA644P
               | ATMEGA644
               | ATMEGA645
               | SAM3X8E
               | X86
               | QUARK
               | UNKNOWN_PROCESSOR Word8
    deriving Show

getProcessor :: Word8 -> Processor
getProcessor  0 = ATMEGA8
getProcessor  1 = ATMEGA168
getProcessor  2 = ATMEGA328P
getProcessor  3 = ATMEGA1280
getProcessor  4 = ATMEGA256
getProcessor  5 = ATMEGA32U4
getProcessor  6 = ATMEGA644P
getProcessor  7 = ATMEGA644
getProcessor  8 = ATMEGA645
getProcessor  9 = SAM3X8E
getProcessor 10 = X86
getProcessor 11 = QUARK
getProcessor  n = UNKNOWN_PROCESSOR n
