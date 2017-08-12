-------------------------------------------------------------------------------
-- |
-- Module      :  System.Hardware.Haskino.ShallowDeepPlugin.AbsThenPass
-- Copyright   :  (c) University of Kansas
-- License     :  BSD3
-- Stability   :  experimental
--
-- Eliminate abs after >> pass
-- forall (f :: Arduino (Expr a)) (g :: Arduino (Expr b))
--     (abs <$> f) >> g
--        =
--     f >> g
-------------------------------------------------------------------------------
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE TemplateHaskell #-}
module System.Hardware.Haskino.ShallowDeepPlugin.AbsThenPass (absThenPass) where

import CoreMonad
import GhcPlugins
import Data.Functor
import Control.Monad.Reader
import Var

import System.Hardware.Haskino.ShallowDeepPlugin.Utils

data BindEnv
    = BindEnv
      { pluginModGuts :: ModGuts
      }

newtype BindM a = BindM { runBindM :: ReaderT BindEnv CoreM a }
    deriving (Functor, Applicative, Monad
             ,MonadIO, MonadReader BindEnv)

instance PassCoreM BindM where
  liftCoreM = BindM . ReaderT . const
  getModGuts = BindM $ ReaderT (return . pluginModGuts)

absThenPass :: ModGuts -> CoreM ModGuts
absThenPass guts =
    bindsOnlyPass (\x -> (runReaderT (runBindM $ (mapM absThen) x) (BindEnv guts))) guts

absThen :: CoreBind -> BindM CoreBind
absThen bndr@(NonRec b e) = do
  let (bs, e') = collectBinders e
  e'' <- absThenExpr e'
  let e''' = mkLams bs e''
  return (NonRec b e''')
absThen bndr@(Rec bs) = do
  bs' <- absThen' bs
  return $ Rec bs'

absThen' :: [(Id, CoreExpr)] -> BindM [(Id, CoreExpr)]
absThen' [] = return []
absThen' ((b, e) : bs) = do
  let (lbs, e') = collectBinders e
  e'' <- absThenExpr e'
  let e''' = mkLams lbs e''
  bs' <- absThen' bs
  return $ (b, e''') : bs'

absThenExpr :: CoreExpr -> BindM CoreExpr
absThenExpr e = do
  df <- liftCoreM getDynFlags
  thenId <- thNameToId bindThenNameTH
  fmapId <- thNameToId fmapNameTH
  absId  <- thNameToId absNameTH
  case e of
    Var v -> return $ Var v
    Lit l -> return $ Lit l
    Type ty -> return $ Type ty
    Coercion co -> return $ Coercion co
    -- Look for expressions of the form:
    -- forall (f :: Arduino (Expr a)) (g :: Arduino (Expr b))
    --     (abs <$> f) >> g
    (Var thenV) :$ (Type m1Ty) :$ dict1 :$ (Type arg1Ty) :$ (Type arg2Ty) :$ 
      ((Var fmapV) :$ (Type m2Ty) :$ (Type arg3Ty) :$ (Type arg4Ty) :$ dict2 :$ 
        ((Var abs_V ) :$ (Type arg5Ty)) :$ e1) :$ e2 | thenV == thenId && fmapV == fmapId && abs_V == absId -> do
      e1' <- absThenExpr e1
      e2' <- absThenExpr e2
      return ((Var thenV) :$ (Type m1Ty) :$ dict1 :$ (Type arg1Ty) :$ (Type arg2Ty) :$ e1' :$ e2')
    App e1 e2 -> do
      e1' <- absThenExpr e1
      e2' <- absThenExpr e2
      return $ App e1' e2'
    Lam tb e -> do
      e' <- absThenExpr e
      return $ Lam tb e'
    Let bind body -> do
      body' <- absThenExpr body
      bind' <- case bind of
                  (NonRec v e) -> do
                    e' <- absThenExpr e
                    return $ NonRec v e'
                  (Rec rbs) -> do
                    rbs' <- absThenExpr' rbs
                    return $ Rec rbs'
      return $ Let bind' body'
    Case e tb ty alts -> do
      e' <- absThenExpr e
      alts' <- absThenExprAlts alts
      return $ Case e' tb ty alts'
    Tick t e -> do
      e' <- absThenExpr e
      return $ Tick t e'
    Cast e co -> do
      e' <- absThenExpr e
      return $ Cast e' co

absThenExpr' :: [(Id, CoreExpr)] -> BindM [(Id, CoreExpr)]
absThenExpr' [] = return []
absThenExpr' ((b, e) : bs) = do
  e' <- absThenExpr e
  bs' <- absThenExpr' bs
  return $ (b, e') : bs'

absThenExprAlts :: [GhcPlugins.Alt CoreBndr] -> BindM [GhcPlugins.Alt CoreBndr]
absThenExprAlts [] = return []
absThenExprAlts ((ac, b, a) : as) = do
  a' <- absThenExpr a
  bs' <- absThenExprAlts as
  return $ (ac, b, a') : bs'

