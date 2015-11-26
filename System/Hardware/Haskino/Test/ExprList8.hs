-------------------------------------------------------------------------------
-- |
-- Module      :  System.Hardware.Haskino.Test.ExprList8
-- Copyright   :  (c) University of Kansas
-- License     :  BSD3
-- Stability   :  experimental
--
-- Quick Check tests for Expressions returning a Expr List8
-------------------------------------------------------------------------------

{-# LANGUAGE GADTs, ScopedTypeVariables, DataKinds #-}

module System.Hardware.Haskino.Test.ExprList8 where

import Prelude hiding 
  ( quotRem, divMod, quot, rem, div, mod, properFraction, fromInteger, toInteger )
import qualified Prelude as P
import System.Hardware.Haskino
import Data.Boolean
import Data.Boolean.Numbers
import Data.Boolean.Bits
import Data.Word
import qualified Data.Bits as DB
import Test.QuickCheck hiding ((.&.))
import Test.QuickCheck.Monadic

litEvalL :: Expr [Word8] -> [Word8]
litEvalL (LitList8 l) = l

litEval8 :: Expr Word8 -> Word8
litEval8 (LitW8 w) = w

litEvalB :: Expr Bool -> Bool
litEvalB (LitB b) = b

prop_cons :: ArduinoConnection -> RemoteRef [Word8] -> Word8  -> [Word8] -> Property
prop_cons c r x xs = monadicIO $ do
    let local = x : xs
    remote <- run $ send c $ do
        writeRemoteRef r $ (lit x) *: (lit xs)
        v <- readRemoteRef r
        return v
    assert (local == litEvalL remote)

prop_app :: ArduinoConnection -> RemoteRef [Word8] -> [Word8]  -> [Word8] -> Property
prop_app c r xs ys = monadicIO $ do
    let local = xs ++ ys
    remote <- run $ send c $ do
        writeRemoteRef r $ (lit xs) ++* (lit ys)
        v <- readRemoteRef r
        return v
    assert (local == litEvalL remote)

prop_len :: ArduinoConnection -> RemoteRef Word8 -> [Word8] -> Property
prop_len c r xs = monadicIO $ do
    let local = length xs
    remote <- run $ send c $ do
        writeRemoteRef r $ len (lit xs)
        v <- readRemoteRef r
        return v
    assert (local == (fromIntegral $ litEval8 remote))

prop_elem :: ArduinoConnection -> RemoteRef Word8 -> NonEmptyList Word8 -> Property
prop_elem c r (NonEmpty xs) = 
    forAll (choose (0::Word8, fromIntegral $ length xs - 1)) $ \e ->
        monadicIO $ do
            let local = xs !! (fromIntegral e)
            remote <- run $ send c $ do
                writeRemoteRef r $ (lit xs) !!* (lit e)
                v <- readRemoteRef r
                return v
            assert (local == (fromIntegral $ litEval8 remote))

-- ToDo: generate prop_elem_out_of_bounds

prop_ifb :: ArduinoConnection -> RemoteRef [Word8] -> Bool -> Word8 -> Word8 -> 
            [Word8] -> [Word8] -> Property
prop_ifb c r b x y xs ys = monadicIO $ do
    let local = if b then x : xs else y : ys
    remote <- run $ send c $ do
        writeRemoteRef r $ ifB (lit b) (lit x *: lit xs) (lit y *: lit ys)
        v <- readRemoteRef r
        return v
    assert (local == litEvalL remote)

prop_eq :: ArduinoConnection -> RemoteRef Bool -> [Word8] -> [Word8] -> Property
prop_eq c r x y = monadicIO $ do
    let local = x == y
    remote <- run $ send c $ do
        writeRemoteRef r $ (lit x) ==* (lit y)
        v <- readRemoteRef r
        return v
    assert (local == litEvalB remote)

prop_neq :: ArduinoConnection -> RemoteRef Bool -> [Word8] -> [Word8] -> Property
prop_neq c r x y = monadicIO $ do
    let local = x /= y
    remote <- run $ send c $ do
        writeRemoteRef r $ (lit x) /=* (lit y)
        v <- readRemoteRef r
        return v
    assert (local == litEvalB remote)

prop_lt :: ArduinoConnection -> RemoteRef Bool -> [Word8] -> [Word8] -> Property
prop_lt c r x y = monadicIO $ do
    let local = x < y
    remote <- run $ send c $ do
        writeRemoteRef r $ (lit x) <* (lit y)
        v <- readRemoteRef r
        return v
    assert (local == litEvalB remote)

prop_gt :: ArduinoConnection -> RemoteRef Bool -> [Word8] -> [Word8] -> Property
prop_gt c r x y = monadicIO $ do
    let local = x > y
    remote <- run $ send c $ do
        writeRemoteRef r $ (lit x) >* (lit y)
        v <- readRemoteRef r
        return v
    assert (local == litEvalB remote)

prop_lte :: ArduinoConnection -> RemoteRef Bool -> [Word8] -> [Word8] -> Property
prop_lte c r x y = monadicIO $ do
    let local = x <= y
    remote <- run $ send c $ do
        writeRemoteRef r $ (lit x) <=* (lit y)
        v <- readRemoteRef r
        return v
    assert (local == litEvalB remote)

prop_gte :: ArduinoConnection -> RemoteRef Bool -> [Word8] -> [Word8] -> Property
prop_gte c r x y = monadicIO $ do
    let local = x >= y
    remote <- run $ send c $ do
        writeRemoteRef r $ (lit x) >=* (lit y)
        v <- readRemoteRef r
        return v
    assert (local == litEvalB remote)

main :: IO ()
main = do
    conn <- openArduino False "/dev/cu.usbmodem1421"
    refL <- send conn $ newRemoteRef (lit [])
    refW8 <- send conn $ newRemoteRef (lit 0)
    refB <- send conn $ newRemoteRef (lit False)
    print "Cons Tests:"
    quickCheck (prop_cons conn refL)
    print "Apppend Tests:"
    quickCheck (prop_app conn refL)
    print "Length Tests:"
    quickCheck (prop_len conn refW8)
    print "Element Tests:"
    quickCheck (prop_len conn refW8)
    print "ifB Tests:"
    quickCheck (prop_ifb conn refL)
    print "Equal Tests:"
    quickCheck (prop_eq conn refB)
    print "Not Equal Tests:"
    quickCheck (prop_neq conn refB)
    print "Less Than Tests:"
    quickCheck (prop_lt conn refB)
    print "Greater Than Tests:"
    quickCheck (prop_gt conn refB)
    print "Less Than Equal Tests:"
    quickCheck (prop_lte conn refB)
    print "Greater Than Equal Tests:"
    quickCheck (prop_gte conn refB)
    closeArduino conn
