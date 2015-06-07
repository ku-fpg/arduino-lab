-------------------------------------------------------------------------------
-- |
-- Module      :  System.Hardware.Arduino.Protocol
-- Copyright   :  (c) Levent Erkok
-- License     :  BSD3
-- Maintainer  :  erkokl@gmail.com
-- Stability   :  experimental
--
-- Internal representation of the firmata protocol.
-------------------------------------------------------------------------------
{-# LANGUAGE GADTs      #-}

module System.Hardware.DeepArduino.Protocol(packageProcedure, packageQuery, unpackageSysEx, unpackageNonSysEx, parseQueryResult) where

import Data.Bits ((.|.), (.&.))
import Data.Word (Word8)

import qualified Data.ByteString as B
import qualified Data.Map        as M

import System.Hardware.DeepArduino.Data
import System.Hardware.DeepArduino.Utils

-- | Wrap a sys-ex message to be sent to the board
sysEx :: SysExCmd -> [Word8] -> B.ByteString
sysEx cmd bs = B.pack $  firmataCmdVal START_SYSEX
                      :  sysExCmdVal cmd
                      :  bs
                      ++ [firmataCmdVal END_SYSEX]

-- | Construct a non sys-ex message
nonSysEx :: FirmataCmd -> [Word8] -> B.ByteString
nonSysEx cmd bs = B.pack $ firmataCmdVal cmd : bs

-- | Package a request as a sequence of bytes to be sent to the board
-- using the Firmata protocol.
packageProcedure :: Procedure -> B.ByteString
packageProcedure SystemReset              = nonSysEx SYSTEM_RESET            []
packageProcedure (AnalogReport  p b)      = nonSysEx (REPORT_ANALOG_PIN (getInternalPin p))   [if b then 1 else 0]
packageProcedure (DigitalReport p b)      = nonSysEx (REPORT_DIGITAL_PORT p) [if b then 1 else 0]
packageProcedure (SetPinMode p m)         = nonSysEx SET_PIN_MODE            [fromIntegral (pinNo (getInternalPin p)), fromIntegral (fromEnum m)]
packageProcedure (DigitalPortWrite p l m) = nonSysEx (DIGITAL_MESSAGE p)     [l, m]
packageProcedure (DigitalPinWrite p b)    = nonSysEx SET_DIGITAL_PIN_VALUE   [fromIntegral (pinNo (getInternalPin p)), if b then 1 else 0]
packageProcedure (AnalogPinWrite p l m)   = nonSysEx (ANALOG_MESSAGE (getInternalPin p))      [l, m]
packageProcedure (AnalogPinExtendedWrite p w8s) = sysEx EXTENDED_ANALOG      ([fromIntegral (pinNo (getInternalPin p))] ++ w8s)
packageProcedure (SamplingInterval l m)   = sysEx    SAMPLING_INTERVAL       [l, m]
packageProcedure (I2CWrite m sa w16s)     = sysEx    I2C_REQUEST     ((packageI2c m False sa Nothing) ++
                                                                      (words16ToArduinoBytes w16s)) 
packageProcedure (CreateTask tid tl)      = sysEx SCHEDULER_DATA ([schedulerCmdVal CREATE_TASK, tid] ++ (word16ToArduinoBytes tl))
packageProcedure (DeleteTask tid)         = sysEx SCHEDULER_DATA [schedulerCmdVal DELETE_TASK, tid]
packageProcedure (DelayTask tt)           = sysEx SCHEDULER_DATA ([schedulerCmdVal DELAY_TASK] ++ (word32ToArduinoBytes tt))
packageProcedure (ScheduleTask tid tt)    = sysEx SCHEDULER_DATA ([schedulerCmdVal DELAY_TASK, tid] ++ (word32ToArduinoBytes tt))

-- | Package a task request as a sequence of bytes to be sent to the board
-- using the Firmata protocol.
-- packageTaskProcedure :: TaskProcedure -> B.ByteString
-- TBD Add AddToTask

packageQuery :: Query a -> B.ByteString
packageQuery QueryFirmware            = sysEx    REPORT_FIRMWARE         []
packageQuery CapabilityQuery          = sysEx    CAPABILITY_QUERY        []
packageQuery AnalogMappingQuery       = sysEx    ANALOG_MAPPING_QUERY    []
packageQuery (Pulse p b dur to)       = sysEx    PULSE                   ([fromIntegral (pinNo p), if b then 1 else 0] ++ concatMap toArduinoBytes (word32ToBytes dur ++ word32ToBytes to))
packageQuery (I2CRead m sa sr)        = sysEx    I2C_REQUEST  (packageI2c m False sa sr)
packageQuery QueryAllTasks            = sysEx    SCHEDULER_DATA [schedulerCmdVal QUERY_ALL_TASKS]
packageQuery (QueryTask tid)          = sysEx    SCHEDULER_DATA [schedulerCmdVal QUERY_TASK, tid]

packageI2c :: I2CAddrMode -> Bool -> SlaveAddress -> Maybe SlaveRegister -> [Word8]
packageI2c m w sa sr = [addrBytes !! 0, commandByte] ++ slaveBytes
  where
    addrBytes = word16ToArduinoBytes sa
    commandByte = (firmataI2CModeVal m) .&. writeByte .&. (addrBytes !! 1)
    writeByte = if w then 0x00 else 0x08
    slaveBytes = case sr of 
                    Nothing -> []
                    Just r  -> word16ToArduinoBytes r

-- | Unpackage a SysEx response
unpackageSysEx :: [Word8] -> Response
unpackageSysEx []              = Unimplemented (Just "<EMPTY-SYSEX-CMD>") []
unpackageSysEx (cmdWord:args)
  | Right cmd <- getSysExCommand cmdWord
  = case (cmd, args) of
      (REPORT_FIRMWARE, majV : minV : rest) -> Firmware majV minV (getString rest)
      (CAPABILITY_RESPONSE, bs)             -> Capabilities (getCapabilities bs)
      (ANALOG_MAPPING_RESPONSE, bs)         -> AnalogMapping bs
      (PULSE, xs) | length xs == 10         -> let [p, a, b, c, d] = fromArduinoBytes xs in PulseResponse (InternalPin p) (bytesToWord32 (a, b, c, d))
      (I2C_REPLY, xs)                       -> let (sa:sr:idata) = arduinoBytesToWords16 xs in I2CReply sa sr idata
      (SCHEDULER_DATA, srWord : ts) | Right sr <- getSchedulerReply srWord
          -> case sr of 
            QUERY_ALL_TASKS_REPLY           -> QueryAllTasksReply ts
    -- TBD add other scheduler responses
      _                                     -> Unimplemented (Just (show cmd)) args
  | True
  = Unimplemented Nothing (cmdWord : args)

-- This is how we match responses with queries TBD need to handle mismatches
-- TBD need to add new queries
parseQueryResult :: Query a -> Response -> a
parseQueryResult QueryFirmware (Firmware wa wb s) = (wa,wb,s)
parseQueryResult CapabilityQuery (Capabilities bc) = bc
parseQueryResult AnalogMappingQuery (AnalogMapping ms) = ms
parseQueryResult (Pulse p b dur to) (PulseResponse p2 w) = w
parseQueryResult (I2CRead am saq srq) (I2CReply sar srr ds) = ds
parseQueryResult QueryAllTasks (QueryAllTasksReply ts) = ts

getCapabilities :: [Word8] -> BoardCapabilities
getCapabilities bs = BoardCapabilities $ M.fromList $ zipWith (\p c -> (p, PinCapabilities{analogPinNumber = Nothing, allowedModes = c}))
                                                              (map InternalPin [(0::Word8)..]) (map pinCaps (chunk bs))
  where chunk xs = case break (== 0x7f) xs of
                     ([], [])         -> []
                     (cur, 0x7f:rest) -> cur : chunk rest
                     _                -> [xs]
        pinCaps (x:y:rest) = (toEnum (fromIntegral x), y) : pinCaps rest
        pinCaps _          = []

-- | Unpackage a Non-SysEx response
unpackageNonSysEx :: (Int -> IO [Word8]) -> FirmataCmd -> IO Response
unpackageNonSysEx getBytes c = grab c
 where unimplemented n = Unimplemented (Just (show c)) `fmap` getBytes n
       grab (ANALOG_MESSAGE       p)    = getBytes 2 >>= \[l, h] -> return (AnalogMessage  p l h)
       grab (DIGITAL_MESSAGE      p)    = getBytes 2 >>= \[l, h] -> return (DigitalMessage p l h)
       -- we should never see any of the following since they are "request" codes
       -- TBD: Maybe we should put them in a different data-type
       grab (REPORT_ANALOG_PIN   _pin)  = unimplemented 1
       grab (REPORT_DIGITAL_PORT _port) = unimplemented 1
       grab START_SYSEX                 = unimplemented 0
       grab SET_PIN_MODE                = unimplemented 2
       grab END_SYSEX                   = unimplemented 0
       grab PROTOCOL_VERSION            = unimplemented 2
       grab SYSTEM_RESET                = unimplemented 0
