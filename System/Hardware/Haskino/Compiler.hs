-------------------------------------------------------------------------------
-- |
-- Module      :  System.Hardware.Haskino.Compiler
-- Copyright   :  (c) University of Kansas
--                System.Hardware.Arduino (c) Levent Erkok
-- License     :  BSD3
-- Stability   :  experimental
--
-- 'C' code generator for the Haskino Library.
-------------------------------------------------------------------------------
{-# LANGUAGE GADTs #-}
{-# LANGUAGE ScopedTypeVariables #-}

module System.Hardware.Haskino.Compiler(compileProgram, compileProgramE) where

import           Control.Monad.State
import           Control.Remote.Applicative.Types as T
import           Control.Remote.Monad
import           Control.Remote.Monad.Types       as T
import           Data.Boolean
import           Data.Char
import           Data.Word                        (Word32, Word8)
import           System.Hardware.Haskino.Data
import           System.Hardware.Haskino.Expr

data Compilable = forall a . ExprB a => MkCompilable (Arduino (Expr a))

data CompilableExpr  = forall a . ExprB a => MkCompilableExpr (Expr a)

data CompileState = CompileState {level :: Int
                     , intTask          :: Bool
                     , ix               :: Int
                     , ib               :: Int
                     , cmds             :: String
                     , binds            :: String
                     , refs             :: String
                     , forwards         :: String
                     , cmdList          :: [String]
                     , bindList         :: [String]
                     , bindsInside      :: [Bool]
                     , tasksToDo        :: [(Arduino (Expr ()), String, Bool)]
                     , funcsToDo        :: [(Compilable, CompileType, String)]
                     , funcExprsToDo    :: [(CompilableExpr, CompileType, String)]
                     , tasksDone        :: [String]
                     , funcsDone        :: [String]
                     , funcExprsDone    :: [String]
                     , errors           :: [String]
                     , iterBinds        :: [(Int, Int)]
                     }

data CompileType =
    UnitType
  | BoolType
  | Word8Type
  | Word16Type
  | Word32Type
  | Int8Type
  | Int16Type
  | Int32Type
  | IntType
  | List8Type
  | FloatType
  deriving (Show, Eq)

compileTypeToString :: CompileType -> String
compileTypeToString UnitType   = "uint8_t"
compileTypeToString BoolType   = "bool"
compileTypeToString Word8Type  = "uint8_t"
compileTypeToString Word16Type = "uint16_t"
compileTypeToString Word32Type = "uint32_t"
compileTypeToString Int8Type   = "int8_t"
compileTypeToString Int16Type  = "int16_t"
compileTypeToString Int32Type  = "int32_t"
compileTypeToString IntType    = "int32_t"
compileTypeToString List8Type  = "uint8_t *"
compileTypeToString FloatType  = "float"

refName :: String
refName = "ref"

argName :: String
argName = "arg"

bindName :: String
bindName = "bind"

indentString :: String
indentString = "    "

mainEntry :: String
mainEntry = "haskinoMain"

stackSizeStr :: String
stackSizeStr = "_STACK_SIZE"

tcbStr :: String
tcbStr = "Tcb"

indent :: Int -> String
indent k = concat $ replicate k indentString

defaultTaskStackSize :: Int
defaultTaskStackSize = 64

contextTaskStackSize :: Int
contextTaskStackSize = 36

taskStackSize :: Int -> Int
taskStackSize bs = bs * 4 + defaultTaskStackSize + contextTaskStackSize;

nextBind :: State CompileState Int
nextBind = do
    s <- get
    put s {ib = (ib s) + 1}
    return (ib s)

compileProgram :: Arduino () -> FilePath -> IO ()
compileProgram p f = compileProgramE (lit <$> p) f

compileProgramE :: Arduino (Expr ()) -> FilePath -> IO ()
compileProgramE p f = do
    writeFile f prog
    if (length $ errors st) == 0
    then putStrLn "Compile Successful"
    else putStrLn $ (show $ length $ errors st) ++ " Errors :"
    mapM_ putStrLn $ errors st
  where
    (_, st) = runState compileTasks
                (CompileState 0 False 0 0 "" "" "" "" [] [] [True] [(p, mainEntry, False)] [] [] [] [] [] [] [])
    prog = "#include \"HaskinoRuntime.h\"\n\n" ++
           forwards st ++ "\n" ++
           "void setup()\n" ++
           "    {\n" ++
           "    haskinoMemInit();\n" ++
           "    createTask(255, " ++ mainEntry ++ tcbStr ++ ", " ++
                (map toUpper mainEntry) ++ stackSizeStr ++ ", " ++
                mainEntry ++ ");\n" ++
           "    scheduleTask(255, 0);\n" ++
           "    startScheduler();\n" ++
           "    }\n\n" ++
           "void loop()\n" ++
           "    {\n" ++
           "    }\n\n" ++
           refs st ++ "\n" ++ (concat $ funcsDone st) ++ (concat $ funcExprsDone st) ++ (concat $ tasksDone st)

compileTasks :: State CompileState ()
compileTasks = do
    s <- get
    let tasks = tasksToDo s
    if null tasks
    then do
      compileFunctions
      compileExprFunctions
    else do
        put s {tasksToDo = tail tasks}
        let (m, name, int) = head tasks
        compileTask m name int
        compileTasks

compileFunctions :: State CompileState ()
compileFunctions = do
    s <- get
    let funcs = funcsToDo s
    if null funcs
    then return ()
    else do
        put s {funcsToDo = tail funcs}
        case head funcs of
           (MkCompilable m, t, name) -> do
              compileFunction m t name
              compileFunctions

compileExprFunctions :: State CompileState ()
compileExprFunctions = do
    s <- get
    let funcExprs = funcExprsToDo s
    if null funcExprs
    then return ()
    else do
        put s {funcExprsToDo = tail funcExprs}
        case head funcExprs of
           (MkCompilableExpr f, t, name) -> do
              compileExprFunction f t name
              compileExprFunctions

compileTask :: Arduino (Expr ()) -> String -> Bool -> State CompileState ()
compileTask t name int = do
    s <- get
    put s {level = 0, intTask = int, ib = 0, cmds = "",
           binds = "", cmdList = [], bindList = []}
    let taskSig = "void " ++ name ++ "()"
    _ <- compileLine taskSig
    _ <- compileForward $ taskSig ++ ";"
    _ <- compileCodeBlock True "" t
    _ <- if not int
         then compileLineIndent "taskComplete();"
         else return LitUnit
    _ <- compileLineIndent "}"
    s' <- get
    let defineStr = (map toUpper name) ++ stackSizeStr
    _ <- compileForward $ "#define " ++ defineStr ++ " " ++
                     (show $ taskStackSize $ ib s')
    _ <- compileForward $ "byte " ++ name ++ tcbStr ++ "[sizeof(TCB) + " ++
                     defineStr ++ "];"
    s'' <- get
    put s'' {tasksDone = cmds s'' : tasksDone s''}
    return ()

compileFunction :: Arduino (Expr a) -> CompileType -> String -> State CompileState ()
compileFunction f t name = do
    s <- get
    put s {level = 0, ib = 0, cmds = "",
           binds = "", cmdList = [], bindList = []}
    (body, argSig) <- compileArgs2 f
    let funcSig = "uint8_t " ++ name ++ "(" ++ argSig ++ ")"
    _ <- compileLine funcSig
    _ <- compileForward $ funcSig ++ ";"
    r <- compileCodeBlock True "" body
    _ <- if t == UnitType
         then return ()
         else do
            cr <- compileExpr r
            _ <- compileLineIndent $ "return(" ++ cr ++ ");"
            return ()
    _ <- compileLineIndent "}\n"
    s'' <- get
    put s'' {funcsDone = cmds s'' : funcsDone s''}
    return ()

compileArgs2 :: Arduino a -> State CompileState (Arduino a, String)
compileArgs2 (Arduino (T.Appl ( T.Primitive (LamExprWord8Unit v f)))) = do
    (func, string) <- compileArgs2 f
    cv <- compileExpr v
    return (func, "uint8_t " ++ cv ++ if null string then "" else "," ++ string)
  where
compileArgs2 f' = return (f',[])

compileExprFunction :: Expr a -> CompileType -> String -> State CompileState ()
compileExprFunction f t name = do
    s <- get
    put s {level = 0, ib = 0, cmds = "",
           binds = "", cmdList = [], bindList = []}
    (body, argSig) <- compileExprArgs2 f
    let funcSig = compileTypeToString t ++ " " ++ name ++ "(" ++ argSig ++ ")"
    _ <- compileForward $ funcSig ++ ";"
    _ <- compileLine funcSig
    _ <- compileLineIndent "{"    
    cr <- compileExpr body
    _ <- compileLineIndent $ "return(" ++ cr ++ ");"
    _ <- compileLineIndent "}\n"
    s'' <- get
    put s'' {funcExprsDone = cmds s'' : funcExprsDone s''}
    return ()

compileExprArgs2 :: Expr a -> State CompileState (Expr a, String)
compileExprArgs2 (LamW8Unit v f) = do
    (func, string) <- compileExprArgs2 f
    cv <- compileExpr v
    return (func, "uint8_t " ++ cv ++ if null string then "" else ", " ++ string)
compileExprArgs2 (LamW8W8 v f) = do
    (func, string) <- compileExprArgs2 f
    cv <- compileExpr v
    return (func, "uint8_t " ++ cv ++ if null string then "" else ", " ++ string)
compileExprArgs2 f' = return (f',[])

compileLine :: String -> State CompileState (Expr ())
compileLine s = do
    st <- get
    put st { cmds = cmds st ++ (indent $ level st) ++ s ++ "\n"}
    return LitUnit

compileLineIndent :: String -> State CompileState (Expr ())
compileLineIndent s = do
    st <- get
    put st { cmds = cmds st ++ (indent (level st + 1)) ++ s ++ "\n"}
    return LitUnit

compileAllocBind :: String -> State CompileState (Expr ())
compileAllocBind s = do
    st <- get
    let ilvl = if head $ bindsInside st then level st else (level st) - 1
    put st { binds = binds st ++ (indent ilvl) ++  s ++ "\n"}
    return LitUnit

compileAllocRef :: String -> State CompileState (Expr ())
compileAllocRef s = do
    st <- get
    put st { refs = refs st ++ s ++ "\n"}
    return LitUnit

compileForward :: String -> State CompileState (Expr ())
compileForward s = do
    st <- get
    put st { forwards = forwards st ++ s ++ "\n"}
    return LitUnit

compileError :: String -> String -> State CompileState (Expr ())
compileError s1 s2 = do
    _ <- compileLine s1
    st <- get
    put st { errors = s2 : (errors st)}
    return LitUnit

compileShallowPrimitiveError :: String -> State CompileState (Expr ())
compileShallowPrimitiveError s = do
    _ <- compileError ("/* " ++ errmsg ++ " */") errmsg
    return LitUnit
  where
    errmsg = "ERROR - " ++ s ++ " is a Shallow procedure, use Deep version instead."

compileUnsupportedError :: String -> State CompileState (Expr ())
compileUnsupportedError s = do
    _ <- compileError ("/* " ++ errmsg ++ " */") errmsg
    return LitUnit
  where
    errmsg = "ERROR - " ++ s ++ " not suppported by compiler."

compileNoExprCommand :: String -> State CompileState (Expr ())
compileNoExprCommand s = do
    _ <- compileLine (s ++ "();")
    return LitUnit

compile1ExprCommand :: String -> Expr a -> State CompileState (Expr ())
compile1ExprCommand s e = do
    ce <- compileExpr e
    _ <- compileLine (s ++ "(" ++ ce ++ ");")
    return LitUnit

compile2ExprCommand :: String -> Expr a -> Expr b -> State CompileState (Expr ())
compile2ExprCommand s e1 e2 = do
    ce1 <- compileExpr e1
    ce2 <- compileExpr e2
    _ <- compileLine (s ++ "(" ++ ce1 ++ "," ++ ce2 ++ ");")
    return LitUnit

compile3ExprCommand :: String -> Expr a -> Expr b -> Expr c -> State CompileState (Expr ())
compile3ExprCommand s e1 e2 e3 = do
    ce1 <- compileExpr e1
    ce2 <- compileExpr e2
    ce3 <- compileExpr e3
    _ <- compileLine (s ++ "(" ++ ce1 ++ "," ++ ce2 ++ "," ++ ce3 ++ ");")
    return LitUnit

compileWriteRef :: Int -> Expr a -> State CompileState (Expr ())
compileWriteRef i e = do
  ce <- compileExpr e
  _ <- compileLine $ refName ++ show i ++ " = " ++ ce ++ ";"
  return LitUnit

compileWriteListRef :: Int -> Expr a -> State CompileState (Expr ())
compileWriteListRef i e = do
  ce <- compileExpr e
  _ <- compileLine $ "listAssign(&" ++ refName ++ show i ++ ", " ++ ce ++ ");"
  return LitUnit

compilePrimitive :: forall a . ArduinoPrimitive a -> State CompileState a
compilePrimitive prim = case knownResult prim of
                          Just _ -> compileCommand prim
                          Nothing -> compileProcedure prim

compileCommand :: ArduinoPrimitive a -> State CompileState a
compileCommand SystemResetE = return LitUnit
compileCommand (SetPinModeE p m) = compile2ExprCommand "pinMode" p m
compileCommand (DigitalWriteE p b) = compile2ExprCommand "digitalWrite" p b
compileCommand (DigitalPortWriteE p b m) =
    compile3ExprCommand "digitalPortWrite" p b m
compileCommand (AnalogWriteE p w) = compile2ExprCommand "analogWrite" p w
compileCommand (ToneE p f (Just d)) = compile3ExprCommand "tone" p f d
compileCommand (ToneE p f Nothing) = compile3ExprCommand "tone" p f (lit (0::Word32))
compileCommand (NoToneE p) = compile1ExprCommand "noTone" p
compileCommand (I2CWriteE sa w8s) = compile2ExprCommand "i2cWrite" sa w8s
compileCommand I2CConfigE = compileNoExprCommand "i2cConfig"
compileCommand (SerialBeginE p r) = compile2ExprCommand "serialBegin" p r
compileCommand (SerialEndE p) = compile1ExprCommand "serialEnd" p
compileCommand (SerialWriteE p w) = compile2ExprCommand "serialWrite" p w
compileCommand (SerialWriteListE p w8s) = compile2ExprCommand "serialWriteList" p w8s
compileCommand (StepperSetSpeedE st sp) =
    compile2ExprCommand "stepperSetSpeed" st sp
compileCommand (ServoDetachE sv) =
    compile1ExprCommand "servoDetach" sv
compileCommand (ServoWriteE sv w) =
    compile2ExprCommand "servoWrite" sv w
compileCommand (ServoWriteMicrosE sv w) =
    compile2ExprCommand "servoWriteMicros" sv w
compileCommand (DeleteTask tid) = do
    _ <- compileShallowPrimitiveError $ "deleteTask " ++ show tid
    return ()
compileCommand (DeleteTaskE tid) =
    compile1ExprCommand "deleteTask" tid
compileCommand (CreateTask tid _) = do
    _ <- compileShallowPrimitiveError $ "createTask " ++ show tid
    return ()
compileCommand (CreateTaskE (LitW8 tid) m) = do
    let taskName = "task" ++ show tid
    _ <- compileLine $ "createTask(" ++ show tid ++ ", " ++
                  taskName ++ tcbStr ++ ", " ++
                  (map toUpper taskName) ++ stackSizeStr ++ ", " ++
                  taskName ++ ");"
    s <- get
    put s {tasksToDo = (m, taskName, False) : (tasksToDo s)}
    return LitUnit
compileCommand (ScheduleTask tid m) = do
    _ <- compileShallowPrimitiveError $ "scheduleTask " ++ show tid ++ " " ++ show m
    return ()
compileCommand (ScheduleTaskE tid tt) =
    compile2ExprCommand "scheduleTask" tid tt
compileCommand ScheduleReset = do
    _ <- compileShallowPrimitiveError $ "scheduleReset"
    return ()
compileCommand ScheduleResetE =
    compileNoExprCommand "scheduleReset"
compileCommand (AttachInt p t _) = do
    _ <- compileShallowPrimitiveError $ "sttachInt " ++ show p ++ " " ++ show t
    return ()
compileCommand (AttachIntE p t m) = do
    ct <- compileExpr t
    let taskName = "task" ++ ct
    s <- get
    put s {tasksToDo = addIntTask (tasksToDo s) taskName}
    cp <- compileExpr p
    cm <- compileExpr m
    compileLine ("attachInterrupt(digitalPinToInterrupt(" ++
                                 cp ++ "), task" ++
                                 ct ++ ", " ++
                                 cm ++ ");")
  where
    addIntTask :: [(Arduino (Expr ()), String, Bool)] -> String -> [(Arduino (Expr ()), String, Bool)]
    addIntTask [] _ = []
    addIntTask (t':ts) tn = matchTask t' tn : addIntTask ts tn

    matchTask :: (Arduino (Expr ()), String, Bool) -> String -> (Arduino (Expr ()), String, Bool)
    matchTask (m', tn1, i) tn2 = if tn1 == tn2
                                then (m', tn1, True)
                                else (m', tn1, i)
compileCommand (DetachIntE p) =
    compile1ExprCommand "detachInterrupt" p
compileCommand InterruptsE =
    compileNoExprCommand "interrupts"
compileCommand NoInterruptsE =
    compileNoExprCommand "noInterrupts"
compileCommand (GiveSemE i) =
    compile1ExprCommand "giveSem" i
compileCommand (TakeSemE i) =
    compile1ExprCommand "takeSem" i
compileCommand (WriteRemoteRefBE (RemoteRefB i) e) = compileWriteRef i e
compileCommand (WriteRemoteRefW8E (RemoteRefW8 i) e) = compileWriteRef i e
compileCommand (WriteRemoteRefW16E (RemoteRefW16 i) e) = compileWriteRef i e
compileCommand (WriteRemoteRefW32E (RemoteRefW32 i) e) = compileWriteRef i e
compileCommand (WriteRemoteRefI8E (RemoteRefI8 i) e) = compileWriteRef i e
compileCommand (WriteRemoteRefI16E (RemoteRefI16 i) e) = compileWriteRef i e
compileCommand (WriteRemoteRefI32E (RemoteRefI32 i) e) = compileWriteRef i e
compileCommand (WriteRemoteRefIE (RemoteRefI i) e) = compileWriteRef i e
compileCommand (WriteRemoteRefL8E (RemoteRefL8 i) e) = compileWriteListRef i e
compileCommand (WriteRemoteRefFloatE (RemoteRefFloat i) e) = compileWriteRef i e
compileCommand (ModifyRemoteRefBE (RemoteRefB i) f) = compileWriteRef i f
compileCommand (ModifyRemoteRefW8E (RemoteRefW8 i) f) = compileWriteRef i f
compileCommand (ModifyRemoteRefW16E (RemoteRefW16 i) f) = compileWriteRef i f
compileCommand (ModifyRemoteRefW32E (RemoteRefW32 i) f) = compileWriteRef i f
compileCommand (ModifyRemoteRefI8E (RemoteRefI8 i) f) = compileWriteRef i f
compileCommand (ModifyRemoteRefI16E (RemoteRefI16 i) f) = compileWriteRef i f
compileCommand (ModifyRemoteRefI32E (RemoteRefI32 i) f) = compileWriteRef i f
compileCommand (ModifyRemoteRefIE (RemoteRefI i) f) = compileWriteRef i f
compileCommand (ModifyRemoteRefL8E (RemoteRefL8 i) f) = compileWriteListRef i f
compileCommand (ModifyRemoteRefFloatE (RemoteRefFloat i) f) = compileWriteRef i f
compileCommand _ = error "compileCommand - Unknown command, it may actually be a procedure"

compileSimpleProcedure :: CompileType -> String -> State CompileState Int
compileSimpleProcedure t p = do
    s <- get
    let b = ib s
    put s {ib = b + 1}
    _ <- compileLine $ bindName ++ show b ++ " = " ++ p ++ ";"
    _ <- compileAllocBind $ compileTypeToString t ++ " " ++ bindName ++ show b ++ ";"
    return b

compileSimpleListProcedure :: String -> State CompileState Int
compileSimpleListProcedure p = do
    s <- get
    let b = ib s
    put s {ib = b + 1}
    _ <- compileLine $ "listAssign(&" ++ bindName ++ show b ++ ", " ++ p ++ ");"
    _ <- compileAllocBind $ compileTypeToString List8Type ++ " " ++
                       bindName ++ show b ++ " = NULL;"
    return b

compileNoExprProcedure :: CompileType -> String -> State CompileState Int
compileNoExprProcedure t p = do
    b <- compileSimpleProcedure t (p ++ "()")
    return b

compile1ExprProcedure :: CompileType -> String -> Expr a -> State CompileState Int
compile1ExprProcedure t p e = do
    ce <- compileExpr e
    b <- compileSimpleProcedure t (p ++ "(" ++ ce ++ ")")
    return b

compile2ExprProcedure :: CompileType -> String ->
                         Expr a -> Expr a -> State CompileState Int
compile2ExprProcedure t p e1 e2 = do
    ce1 <- compileExpr e1
    ce2 <- compileExpr e1
    b <- compileSimpleProcedure t (p ++ "(" ++ ce1 ++ "," ++
                                               ce2 ++ ")")
    return b

compile1ExprListProcedure :: String ->
                             Expr a -> State CompileState Int
compile1ExprListProcedure p e1 = do
    ce1 <- compileExpr e1
    b <- compileSimpleListProcedure (p ++ "(" ++ ce1 ++ ")")
    return b

compile2ExprListProcedure :: String ->
                             Expr a -> Expr a -> State CompileState Int
compile2ExprListProcedure p e1 e2 = do
    ce1 <- compileExpr e1
    ce2 <- compileExpr e2
    b <- compileSimpleListProcedure (p ++ "(" ++ ce1 ++ "," ++
                                                 ce2 ++ ")")
    return b

compile3ExprProcedure :: CompileType -> String ->
                         Expr a -> Expr b  -> Expr c -> State CompileState Int
compile3ExprProcedure t p e1 e2 e3 = do
    ce1 <- compileExpr e1
    ce2 <- compileExpr e2
    ce3 <- compileExpr e3
    b <- compileSimpleProcedure t (p ++ "(" ++ ce1 ++ "," ++
                                               ce2 ++ "," ++
                                               ce3 ++ ")")
    return b

compile5ExprProcedure :: CompileType -> String -> Expr a -> Expr b ->
                         Expr c -> Expr d  -> Expr e -> State CompileState Int
compile5ExprProcedure t p e1 e2 e3 e4 e5 = do
    ce1 <- compileExpr e1
    ce2 <- compileExpr e2
    ce3 <- compileExpr e3
    ce4 <- compileExpr e4
    ce5 <- compileExpr e5
    b <- compileSimpleProcedure t (p ++ "(" ++ ce1 ++ "," ++
                                               ce2 ++ "," ++
                                               ce3 ++ "," ++
                                               ce4 ++ "," ++
                                               ce5 ++ ")")
    return b

compileNewRef :: CompileType -> Expr a -> State CompileState Int
compileNewRef t e = do
    s <- get
    let x = ix s
    put s {ix = x + 1}
    _ <- compileAllocRef $ compileTypeToString t ++ " " ++ refName ++ show x ++ ";"
    ce <- compileExpr e
    _ <- compileLine $ refName ++ show x ++ " = " ++ ce ++ ";"
    return  x

compileNewListRef :: Expr a -> State CompileState Int
compileNewListRef e = do
    s <- get
    let x = ix s
    put s {ix = x + 1}
    _ <- compileAllocRef $ compileTypeToString List8Type ++
                      " " ++ refName ++ show x ++ " = NULL;"
    ce <- compileExpr e
    _ <- compileLine $ "listAssign(&" ++ refName ++ show x ++
                  ", " ++ ce ++ ");"
    return  x

compileReadRef :: CompileType -> Int -> State CompileState Int
compileReadRef t ix' = do
    s <- get
    let b = ib s
    put s {ib = b + 1}
    _ <- compileLine $ bindName ++ show b ++ " = " ++ refName ++ show ix' ++ ";"
    _ <- compileAllocBind $ compileTypeToString t ++ " " ++ bindName ++ show b ++ ";"
    return b

compileReadListRef :: Int -> State CompileState Int
compileReadListRef ix' = do
    s <- get
    let b = ib s
    put s {ib = b + 1}
    _ <- compileLine $ "listAssign(&" ++ bindName ++ show b ++ ", " ++
                  refName ++ show ix' ++ ");"
    _ <- compileAllocBind $ compileTypeToString List8Type ++ " " ++
                       bindName ++ show b ++ " = NULL;"
    return b

compileProcedure :: ArduinoPrimitive a -> State CompileState a
compileProcedure QueryFirmware = do
    _ <- compileShallowPrimitiveError "queryFirmware"
    return 0
compileProcedure QueryFirmwareE = do
    b <- compileNoExprProcedure Word16Type "queryFirmware"
    return $ remBind b
compileProcedure QueryProcessor = do
    _ <- compileShallowPrimitiveError "queryProcessor"
    return ATMEGA8
compileProcedure QueryProcessorE = do
    b <- compileNoExprProcedure Word8Type "queryProcessor"
    return $ remBind b
compileProcedure Millis = do
    _ <- compileShallowPrimitiveError "millis"
    return (0::Word32)
compileProcedure MillisE = do
    b <- compileNoExprProcedure Word32Type "millis"
    return $ remBind b
compileProcedure Micros = do
    _ <- compileShallowPrimitiveError "micros"
    return 0
compileProcedure MicrosE = do
    b <- compileNoExprProcedure Word32Type "micros"
    return $ remBind b
compileProcedure (DelayMillis ms) = do
    _ <- compileShallowPrimitiveError $ "delayMillis " ++ show ms
    return ()
compileProcedure (DelayMillisE ms) = do
    _ <- compile1ExprCommand "delayMilliseconds" ms
    return LitUnit
compileProcedure (DelayMicros ms) = do
    _ <- compileShallowPrimitiveError $ "delayMicros " ++ show ms
    return ()
compileProcedure (DelayMicrosE ms) = do
    _ <- compile1ExprCommand "delayMicroseconds" ms
    return LitUnit
compileProcedure (DigitalRead ms) = do
    _ <- compileShallowPrimitiveError $ "digitalRead " ++ show ms
    return False
compileProcedure (DigitalReadE p) = do
    b <- compile1ExprProcedure BoolType "digitalRead" p
    return $ remBind b
compileProcedure (DigitalPortRead p m) = do
    _ <- compileShallowPrimitiveError $ "digitalPortRead " ++ show p ++ " " ++ show m
    return 0
compileProcedure (DigitalPortReadE p m) = do
    b <- compile2ExprProcedure Word8Type "digitalPortRead" p m
    return $ remBind b
compileProcedure (AnalogRead p) = do
    _ <- compileShallowPrimitiveError $ "analogRead " ++ show p
    return 0
compileProcedure (AnalogReadE p) = do
    b <- compile1ExprProcedure Word16Type "analogRead" p
    return $ remBind b
compileProcedure (I2CRead p n) = do
    _ <- compileShallowPrimitiveError $ "i2cRead " ++ show p ++ " " ++ show n
    return []
compileProcedure (I2CReadE p n) = do
    b <- compile2ExprListProcedure "i2cRead" p n
    return $ remBind b
compileProcedure (SerialAvailable p) = do
    _ <- compileShallowPrimitiveError $ "serialAvailable " ++ show p
    return 0
compileProcedure (SerialAvailableE p) = do
    b <- compile1ExprProcedure Word32Type "serialAvailable" p
    return $ remBind b
compileProcedure (SerialRead p) = do
    _ <- compileShallowPrimitiveError $ "serialRead " ++ show p
    return 0
compileProcedure (SerialReadE p) = do
    b <- compile1ExprProcedure Int32Type "serialRead" p
    return $ remBind b
compileProcedure (SerialReadList p) = do
    _ <- compileShallowPrimitiveError $ "serialReadList " ++ show p
    return []
compileProcedure (SerialReadListE p) = do
    b <- compile1ExprListProcedure "serialReadList" p
    return $ remBind b
compileProcedure (Stepper2Pin s p1 p2) = do
    _ <- compileShallowPrimitiveError $ "i2cRead " ++ show s ++ " " ++
                                   show p1 ++ " " ++ show p2
    return 0
compileProcedure (Stepper2PinE s p1 p2) = do
    b <- compile3ExprProcedure Word8Type "stepper2Pin" s p1 p2
    return $ remBind b
compileProcedure (Stepper4Pin s p1 p2 p3 p4) = do
    _ <- compileShallowPrimitiveError $ "i2cRead " ++ show s ++ " " ++
                                   show p1 ++ " " ++ show p2 ++
                                   show p3 ++ " " ++ show p4
    return 0
compileProcedure (Stepper4PinE s p1 p2 p3 p4) = do
    b <- compile5ExprProcedure Word8Type "stepper4Pin" s p1 p2 p3 p4
    return $ remBind b
compileProcedure (StepperStepE st s) = do
    _ <- compile2ExprCommand "stepperStep" st s
    return ()
compileProcedure (ServoAttach p) = do
    _ <- compileShallowPrimitiveError $ "servoAttach " ++ show p
    return 0
compileProcedure (ServoAttachE p) = do
    b <- compile1ExprProcedure Word8Type "servoAttach" p
    return $ remBind b
compileProcedure (ServoAttachMinMax p mi ma) = do
    _ <- compileShallowPrimitiveError $ "servoAttachMinMax " ++
                           show p ++ " " ++ show mi ++ " " ++ show ma
    return 0
compileProcedure (ServoAttachMinMaxE p mi ma) = do
    b <- compile3ExprProcedure Word8Type "servoAttachMinMax" p mi ma
    return $ remBind b
compileProcedure (ServoRead sv) = do
    _ <- compileShallowPrimitiveError $ "servoRead " ++ show sv
    return 0
compileProcedure (ServoReadE sv) = do
    b <- compile1ExprProcedure Word16Type "servoRead" sv
    return $ remBind b
compileProcedure (ServoReadMicros sv) = do
    _ <- compileShallowPrimitiveError $ "servoReadMicros" ++ show sv
    return 0
compileProcedure (ServoReadMicrosE sv) = do
    b <- compile1ExprProcedure Word16Type "servoReadMicros" sv
    return $ remBind b
compileProcedure QueryAllTasks = do
    _ <- compileUnsupportedError "queryAllTasks"
    return []
compileProcedure QueryAllTasksE = do
    _ <- compileUnsupportedError "queryAllTasksE"
    return (litStringE "")
compileProcedure (QueryTaskE _) = do
    _ <- compileUnsupportedError "queryTaskE"
    return Nothing
compileProcedure (QueryTask _) = do
    _ <- compileUnsupportedError "queryTask"
    return Nothing
compileProcedure (BootTaskE _) = do
    _ <- compileUnsupportedError "bootTaskE"
    return true
compileProcedure (Debug _) = do
    return ()
compileProcedure (DebugE s) = do
    cs <- compileExpr s
    _ <- compileLine ("debug((uint8_t *)" ++ cs ++ ");")
    return ()
compileProcedure DebugListen = do
    return ()
compileProcedure (Die _ _) = do
    _ <- compileUnsupportedError "die"
    return ()
compileProcedure (NewRemoteRefBE e) = do
    x <- compileNewRef BoolType e
    return $ RemoteRefB x
compileProcedure (NewRemoteRefW8E e) = do
    x <- compileNewRef Word8Type e
    return $ RemoteRefW8 x
compileProcedure (NewRemoteRefW16E e) = do
    x <- compileNewRef Word16Type e
    return $ RemoteRefW16 x
compileProcedure (NewRemoteRefW32E e) = do
    x <- compileNewRef Word32Type e
    return $ RemoteRefW32 x
compileProcedure (NewRemoteRefI8E e) = do
    x <- compileNewRef Int8Type e
    return $ RemoteRefI8 x
compileProcedure (NewRemoteRefI16E e) = do
    x <- compileNewRef Int16Type e
    return $ RemoteRefI16 x
compileProcedure (NewRemoteRefI32E e) = do
    x <- compileNewRef Int32Type e
    return $ RemoteRefI32 x
compileProcedure (NewRemoteRefIE e) = do
    x <- compileNewRef IntType e
    return $ RemoteRefI x
compileProcedure (NewRemoteRefL8E e) = do
    x <- compileNewListRef e
    return $ RemoteRefL8 x
compileProcedure (NewRemoteRefFloatE e) = do
    x <- compileNewRef FloatType e
    return $ RemoteRefFloat x
compileProcedure (ReadRemoteRefBE (RemoteRefB i)) = do
    b <- compileReadRef BoolType i
    return $ remBind b
compileProcedure (ReadRemoteRefW8E (RemoteRefW8 i)) = do
    b <- compileReadRef Word8Type i
    return $ remBind b
compileProcedure (ReadRemoteRefW16E (RemoteRefW16 i)) = do
    b <- compileReadRef Word16Type i
    return $ remBind b
compileProcedure (ReadRemoteRefW32E (RemoteRefW32 i)) = do
    b <- compileReadRef Word32Type i
    return $ remBind b
compileProcedure (ReadRemoteRefI8E (RemoteRefI8 i)) = do
    b <- compileReadRef Int8Type i
    return $ remBind b
compileProcedure (ReadRemoteRefI16E (RemoteRefI16 i)) = do
    b <- compileReadRef Int16Type i
    return $ remBind b
compileProcedure (ReadRemoteRefI32E (RemoteRefI32 i)) = do
    b <- compileReadRef Int32Type i
    return $ remBind b
compileProcedure (ReadRemoteRefL8E (RemoteRefL8 i)) = do
    b <- compileReadListRef i
    return $ remBind b
compileProcedure (ReadRemoteRefFloatE (RemoteRefFloat i)) = do
    b <- compileReadRef FloatType i
    return $ remBind b
compileProcedure (IfThenElseUnitE e cb1 cb2) =
    compileIfThenElseProcedure UnitType e cb1 cb2
compileProcedure (IfThenElseBoolE e cb1 cb2) =
    compileIfThenElseProcedure BoolType e cb1 cb2
compileProcedure (IfThenElseWord8E e cb1 cb2) =
    compileIfThenElseProcedure Word8Type e cb1 cb2
compileProcedure (IfThenElseWord16E e cb1 cb2) =
    compileIfThenElseProcedure Word16Type e cb1 cb2
compileProcedure (IfThenElseWord32E e cb1 cb2) =
    compileIfThenElseProcedure Word32Type e cb1 cb2
compileProcedure (IfThenElseInt8E e cb1 cb2) =
    compileIfThenElseProcedure Int8Type e cb1 cb2
compileProcedure (IfThenElseInt16E e cb1 cb2) =
    compileIfThenElseProcedure Int16Type e cb1 cb2
compileProcedure (IfThenElseInt32E e cb1 cb2) =
    compileIfThenElseProcedure Int32Type e cb1 cb2
compileProcedure (IfThenElseIntE e cb1 cb2) =
    compileIfThenElseProcedure IntType e cb1 cb2
compileProcedure (IfThenElseL8E e cb1 cb2) =
    compileIfThenElseProcedure List8Type e cb1 cb2
compileProcedure (IfThenElseFloatE e cb1 cb2) =
    compileIfThenElseProcedure FloatType e cb1 cb2
-- The following IfThenElse* functions generated by toold/GenEitherTypes.hs
compileProcedure (IfThenElseUnitUnit e cb1 cb2) =
    compileIfThenElseEitherProcedure UnitType UnitType e cb1 cb2
compileProcedure (IfThenElseUnitBool e cb1 cb2) =
    compileIfThenElseEitherProcedure UnitType BoolType e cb1 cb2
compileProcedure (IfThenElseUnitW8 e cb1 cb2) =
    compileIfThenElseEitherProcedure UnitType Word8Type e cb1 cb2
compileProcedure (IfThenElseUnitW16 e cb1 cb2) =
    compileIfThenElseEitherProcedure UnitType Word16Type e cb1 cb2
compileProcedure (IfThenElseUnitW32 e cb1 cb2) =
    compileIfThenElseEitherProcedure UnitType Word32Type e cb1 cb2
compileProcedure (IfThenElseUnitI8 e cb1 cb2) =
    compileIfThenElseEitherProcedure UnitType Int8Type e cb1 cb2
compileProcedure (IfThenElseUnitI16 e cb1 cb2) =
    compileIfThenElseEitherProcedure UnitType Int16Type e cb1 cb2
compileProcedure (IfThenElseUnitI32 e cb1 cb2) =
    compileIfThenElseEitherProcedure UnitType Int32Type e cb1 cb2
compileProcedure (IfThenElseUnitI e cb1 cb2) =
    compileIfThenElseEitherProcedure UnitType IntType e cb1 cb2
compileProcedure (IfThenElseUnitL8 e cb1 cb2) =
    compileIfThenElseEitherProcedure UnitType List8Type e cb1 cb2
compileProcedure (IfThenElseUnitFloat e cb1 cb2) =
    compileIfThenElseEitherProcedure UnitType FloatType e cb1 cb2
compileProcedure (IfThenElseBoolUnit e cb1 cb2) =
    compileIfThenElseEitherProcedure BoolType UnitType e cb1 cb2
compileProcedure (IfThenElseBoolBool e cb1 cb2) =
    compileIfThenElseEitherProcedure BoolType BoolType e cb1 cb2
compileProcedure (IfThenElseBoolW8 e cb1 cb2) =
    compileIfThenElseEitherProcedure BoolType Word8Type e cb1 cb2
compileProcedure (IfThenElseBoolW16 e cb1 cb2) =
    compileIfThenElseEitherProcedure BoolType Word16Type e cb1 cb2
compileProcedure (IfThenElseBoolW32 e cb1 cb2) =
    compileIfThenElseEitherProcedure BoolType Word32Type e cb1 cb2
compileProcedure (IfThenElseBoolI8 e cb1 cb2) =
    compileIfThenElseEitherProcedure BoolType Int8Type e cb1 cb2
compileProcedure (IfThenElseBoolI16 e cb1 cb2) =
    compileIfThenElseEitherProcedure BoolType Int16Type e cb1 cb2
compileProcedure (IfThenElseBoolI32 e cb1 cb2) =
    compileIfThenElseEitherProcedure BoolType Int32Type e cb1 cb2
compileProcedure (IfThenElseBoolI e cb1 cb2) =
    compileIfThenElseEitherProcedure BoolType IntType e cb1 cb2
compileProcedure (IfThenElseBoolL8 e cb1 cb2) =
    compileIfThenElseEitherProcedure BoolType List8Type e cb1 cb2
compileProcedure (IfThenElseBoolFloat e cb1 cb2) =
    compileIfThenElseEitherProcedure BoolType FloatType e cb1 cb2
compileProcedure (IfThenElseW8Unit e cb1 cb2) =
    compileIfThenElseEitherProcedure Word8Type UnitType e cb1 cb2
compileProcedure (IfThenElseW8Bool e cb1 cb2) =
    compileIfThenElseEitherProcedure Word8Type BoolType e cb1 cb2
compileProcedure (IfThenElseW8W8 e cb1 cb2) =
    compileIfThenElseEitherProcedure Word8Type Word8Type e cb1 cb2
compileProcedure (IfThenElseW8W16 e cb1 cb2) =
    compileIfThenElseEitherProcedure Word8Type Word16Type e cb1 cb2
compileProcedure (IfThenElseW8W32 e cb1 cb2) =
    compileIfThenElseEitherProcedure Word8Type Word32Type e cb1 cb2
compileProcedure (IfThenElseW8I8 e cb1 cb2) =
    compileIfThenElseEitherProcedure Word8Type Int8Type e cb1 cb2
compileProcedure (IfThenElseW8I16 e cb1 cb2) =
    compileIfThenElseEitherProcedure Word8Type Int16Type e cb1 cb2
compileProcedure (IfThenElseW8I32 e cb1 cb2) =
    compileIfThenElseEitherProcedure Word8Type Int32Type e cb1 cb2
compileProcedure (IfThenElseW8I e cb1 cb2) =
    compileIfThenElseEitherProcedure Word8Type IntType e cb1 cb2
compileProcedure (IfThenElseW8L8 e cb1 cb2) =
    compileIfThenElseEitherProcedure Word8Type List8Type e cb1 cb2
compileProcedure (IfThenElseW8Float e cb1 cb2) =
    compileIfThenElseEitherProcedure Word8Type FloatType e cb1 cb2
compileProcedure (IfThenElseW16Unit e cb1 cb2) =
    compileIfThenElseEitherProcedure Word16Type UnitType e cb1 cb2
compileProcedure (IfThenElseW16Bool e cb1 cb2) =
    compileIfThenElseEitherProcedure Word16Type BoolType e cb1 cb2
compileProcedure (IfThenElseW16W8 e cb1 cb2) =
    compileIfThenElseEitherProcedure Word16Type Word8Type e cb1 cb2
compileProcedure (IfThenElseW16W16 e cb1 cb2) =
    compileIfThenElseEitherProcedure Word16Type Word16Type e cb1 cb2
compileProcedure (IfThenElseW16W32 e cb1 cb2) =
    compileIfThenElseEitherProcedure Word16Type Word32Type e cb1 cb2
compileProcedure (IfThenElseW16I8 e cb1 cb2) =
    compileIfThenElseEitherProcedure Word16Type Int8Type e cb1 cb2
compileProcedure (IfThenElseW16I16 e cb1 cb2) =
    compileIfThenElseEitherProcedure Word16Type Int16Type e cb1 cb2
compileProcedure (IfThenElseW16I32 e cb1 cb2) =
    compileIfThenElseEitherProcedure Word16Type Int32Type e cb1 cb2
compileProcedure (IfThenElseW16I e cb1 cb2) =
    compileIfThenElseEitherProcedure Word16Type IntType e cb1 cb2
compileProcedure (IfThenElseW16L8 e cb1 cb2) =
    compileIfThenElseEitherProcedure Word16Type List8Type e cb1 cb2
compileProcedure (IfThenElseW16Float e cb1 cb2) =
    compileIfThenElseEitherProcedure Word16Type FloatType e cb1 cb2
compileProcedure (IfThenElseW32Unit e cb1 cb2) =
    compileIfThenElseEitherProcedure Word32Type UnitType e cb1 cb2
compileProcedure (IfThenElseW32Bool e cb1 cb2) =
    compileIfThenElseEitherProcedure Word32Type BoolType e cb1 cb2
compileProcedure (IfThenElseW32W8 e cb1 cb2) =
    compileIfThenElseEitherProcedure Word32Type Word8Type e cb1 cb2
compileProcedure (IfThenElseW32W16 e cb1 cb2) =
    compileIfThenElseEitherProcedure Word32Type Word16Type e cb1 cb2
compileProcedure (IfThenElseW32W32 e cb1 cb2) =
    compileIfThenElseEitherProcedure Word32Type Word32Type e cb1 cb2
compileProcedure (IfThenElseW32I8 e cb1 cb2) =
    compileIfThenElseEitherProcedure Word32Type Int8Type e cb1 cb2
compileProcedure (IfThenElseW32I16 e cb1 cb2) =
    compileIfThenElseEitherProcedure Word32Type Int16Type e cb1 cb2
compileProcedure (IfThenElseW32I32 e cb1 cb2) =
    compileIfThenElseEitherProcedure Word32Type Int32Type e cb1 cb2
compileProcedure (IfThenElseW32I e cb1 cb2) =
    compileIfThenElseEitherProcedure Word32Type IntType e cb1 cb2
compileProcedure (IfThenElseW32L8 e cb1 cb2) =
    compileIfThenElseEitherProcedure Word32Type List8Type e cb1 cb2
compileProcedure (IfThenElseW32Float e cb1 cb2) =
    compileIfThenElseEitherProcedure Word32Type FloatType e cb1 cb2
compileProcedure (IfThenElseI8Unit e cb1 cb2) =
    compileIfThenElseEitherProcedure Int8Type UnitType e cb1 cb2
compileProcedure (IfThenElseI8Bool e cb1 cb2) =
    compileIfThenElseEitherProcedure Int8Type BoolType e cb1 cb2
compileProcedure (IfThenElseI8W8 e cb1 cb2) =
    compileIfThenElseEitherProcedure Int8Type Word8Type e cb1 cb2
compileProcedure (IfThenElseI8W16 e cb1 cb2) =
    compileIfThenElseEitherProcedure Int8Type Word16Type e cb1 cb2
compileProcedure (IfThenElseI8W32 e cb1 cb2) =
    compileIfThenElseEitherProcedure Int8Type Word32Type e cb1 cb2
compileProcedure (IfThenElseI8I8 e cb1 cb2) =
    compileIfThenElseEitherProcedure Int8Type Int8Type e cb1 cb2
compileProcedure (IfThenElseI8I16 e cb1 cb2) =
    compileIfThenElseEitherProcedure Int8Type Int16Type e cb1 cb2
compileProcedure (IfThenElseI8I32 e cb1 cb2) =
    compileIfThenElseEitherProcedure Int8Type Int32Type e cb1 cb2
compileProcedure (IfThenElseI8I e cb1 cb2) =
    compileIfThenElseEitherProcedure Int8Type IntType e cb1 cb2
compileProcedure (IfThenElseI8L8 e cb1 cb2) =
    compileIfThenElseEitherProcedure Int8Type List8Type e cb1 cb2
compileProcedure (IfThenElseI8Float e cb1 cb2) =
    compileIfThenElseEitherProcedure Int8Type FloatType e cb1 cb2
compileProcedure (IfThenElseI16Unit e cb1 cb2) =
    compileIfThenElseEitherProcedure Int16Type UnitType e cb1 cb2
compileProcedure (IfThenElseI16Bool e cb1 cb2) =
    compileIfThenElseEitherProcedure Int16Type BoolType e cb1 cb2
compileProcedure (IfThenElseI16W8 e cb1 cb2) =
    compileIfThenElseEitherProcedure Int16Type Word8Type e cb1 cb2
compileProcedure (IfThenElseI16W16 e cb1 cb2) =
    compileIfThenElseEitherProcedure Int16Type Word16Type e cb1 cb2
compileProcedure (IfThenElseI16W32 e cb1 cb2) =
    compileIfThenElseEitherProcedure Int16Type Word32Type e cb1 cb2
compileProcedure (IfThenElseI16I8 e cb1 cb2) =
    compileIfThenElseEitherProcedure Int16Type Int8Type e cb1 cb2
compileProcedure (IfThenElseI16I16 e cb1 cb2) =
    compileIfThenElseEitherProcedure Int16Type Int16Type e cb1 cb2
compileProcedure (IfThenElseI16I32 e cb1 cb2) =
    compileIfThenElseEitherProcedure Int16Type Int32Type e cb1 cb2
compileProcedure (IfThenElseI16I e cb1 cb2) =
    compileIfThenElseEitherProcedure Int16Type IntType e cb1 cb2
compileProcedure (IfThenElseI16L8 e cb1 cb2) =
    compileIfThenElseEitherProcedure Int16Type List8Type e cb1 cb2
compileProcedure (IfThenElseI16Float e cb1 cb2) =
    compileIfThenElseEitherProcedure Int16Type FloatType e cb1 cb2
compileProcedure (IfThenElseI32Unit e cb1 cb2) =
    compileIfThenElseEitherProcedure Int32Type UnitType e cb1 cb2
compileProcedure (IfThenElseI32Bool e cb1 cb2) =
    compileIfThenElseEitherProcedure Int32Type BoolType e cb1 cb2
compileProcedure (IfThenElseI32W8 e cb1 cb2) =
    compileIfThenElseEitherProcedure Int32Type Word8Type e cb1 cb2
compileProcedure (IfThenElseI32W16 e cb1 cb2) =
    compileIfThenElseEitherProcedure Int32Type Word16Type e cb1 cb2
compileProcedure (IfThenElseI32W32 e cb1 cb2) =
    compileIfThenElseEitherProcedure Int32Type Word32Type e cb1 cb2
compileProcedure (IfThenElseI32I8 e cb1 cb2) =
    compileIfThenElseEitherProcedure Int32Type Int8Type e cb1 cb2
compileProcedure (IfThenElseI32I16 e cb1 cb2) =
    compileIfThenElseEitherProcedure Int32Type Int16Type e cb1 cb2
compileProcedure (IfThenElseI32I32 e cb1 cb2) =
    compileIfThenElseEitherProcedure Int32Type Int32Type e cb1 cb2
compileProcedure (IfThenElseI32I e cb1 cb2) =
    compileIfThenElseEitherProcedure Int32Type IntType e cb1 cb2
compileProcedure (IfThenElseI32L8 e cb1 cb2) =
    compileIfThenElseEitherProcedure Int32Type List8Type e cb1 cb2
compileProcedure (IfThenElseI32Float e cb1 cb2) =
    compileIfThenElseEitherProcedure Int32Type FloatType e cb1 cb2
compileProcedure (IfThenElseIUnit e cb1 cb2) =
    compileIfThenElseEitherProcedure IntType UnitType e cb1 cb2
compileProcedure (IfThenElseIBool e cb1 cb2) =
    compileIfThenElseEitherProcedure IntType BoolType e cb1 cb2
compileProcedure (IfThenElseIW8 e cb1 cb2) =
    compileIfThenElseEitherProcedure IntType Word8Type e cb1 cb2
compileProcedure (IfThenElseIW16 e cb1 cb2) =
    compileIfThenElseEitherProcedure IntType Word16Type e cb1 cb2
compileProcedure (IfThenElseIW32 e cb1 cb2) =
    compileIfThenElseEitherProcedure IntType Word32Type e cb1 cb2
compileProcedure (IfThenElseII8 e cb1 cb2) =
    compileIfThenElseEitherProcedure IntType Int8Type e cb1 cb2
compileProcedure (IfThenElseII16 e cb1 cb2) =
    compileIfThenElseEitherProcedure IntType Int16Type e cb1 cb2
compileProcedure (IfThenElseII32 e cb1 cb2) =
    compileIfThenElseEitherProcedure IntType Int32Type e cb1 cb2
compileProcedure (IfThenElseII e cb1 cb2) =
    compileIfThenElseEitherProcedure IntType IntType e cb1 cb2
compileProcedure (IfThenElseIL8 e cb1 cb2) =
    compileIfThenElseEitherProcedure IntType List8Type e cb1 cb2
compileProcedure (IfThenElseIFloat e cb1 cb2) =
    compileIfThenElseEitherProcedure IntType FloatType e cb1 cb2
compileProcedure (IfThenElseL8Unit e cb1 cb2) =
    compileIfThenElseEitherProcedure List8Type UnitType e cb1 cb2
compileProcedure (IfThenElseL8Bool e cb1 cb2) =
    compileIfThenElseEitherProcedure List8Type BoolType e cb1 cb2
compileProcedure (IfThenElseL8W8 e cb1 cb2) =
    compileIfThenElseEitherProcedure List8Type Word8Type e cb1 cb2
compileProcedure (IfThenElseL8W16 e cb1 cb2) =
    compileIfThenElseEitherProcedure List8Type Word16Type e cb1 cb2
compileProcedure (IfThenElseL8W32 e cb1 cb2) =
    compileIfThenElseEitherProcedure List8Type Word32Type e cb1 cb2
compileProcedure (IfThenElseL8I8 e cb1 cb2) =
    compileIfThenElseEitherProcedure List8Type Int8Type e cb1 cb2
compileProcedure (IfThenElseL8I16 e cb1 cb2) =
    compileIfThenElseEitherProcedure List8Type Int16Type e cb1 cb2
compileProcedure (IfThenElseL8I32 e cb1 cb2) =
    compileIfThenElseEitherProcedure List8Type Int32Type e cb1 cb2
compileProcedure (IfThenElseL8I e cb1 cb2) =
    compileIfThenElseEitherProcedure List8Type IntType e cb1 cb2
compileProcedure (IfThenElseL8L8 e cb1 cb2) =
    compileIfThenElseEitherProcedure List8Type List8Type e cb1 cb2
compileProcedure (IfThenElseL8Float e cb1 cb2) =
    compileIfThenElseEitherProcedure List8Type FloatType e cb1 cb2
compileProcedure (IfThenElseFloatUnit e cb1 cb2) =
    compileIfThenElseEitherProcedure FloatType UnitType e cb1 cb2
compileProcedure (IfThenElseFloatBool e cb1 cb2) =
    compileIfThenElseEitherProcedure FloatType BoolType e cb1 cb2
compileProcedure (IfThenElseFloatW8 e cb1 cb2) =
    compileIfThenElseEitherProcedure FloatType Word8Type e cb1 cb2
compileProcedure (IfThenElseFloatW16 e cb1 cb2) =
    compileIfThenElseEitherProcedure FloatType Word16Type e cb1 cb2
compileProcedure (IfThenElseFloatW32 e cb1 cb2) =
    compileIfThenElseEitherProcedure FloatType Word32Type e cb1 cb2
compileProcedure (IfThenElseFloatI8 e cb1 cb2) =
    compileIfThenElseEitherProcedure FloatType Int8Type e cb1 cb2
compileProcedure (IfThenElseFloatI16 e cb1 cb2) =
    compileIfThenElseEitherProcedure FloatType Int16Type e cb1 cb2
compileProcedure (IfThenElseFloatI32 e cb1 cb2) =
    compileIfThenElseEitherProcedure FloatType Int32Type e cb1 cb2
compileProcedure (IfThenElseFloatI e cb1 cb2) =
    compileIfThenElseEitherProcedure FloatType IntType e cb1 cb2
compileProcedure (IfThenElseFloatL8 e cb1 cb2) =
    compileIfThenElseEitherProcedure FloatType List8Type e cb1 cb2
compileProcedure (IfThenElseFloatFloat e cb1 cb2) =
    compileIfThenElseEitherProcedure FloatType FloatType e cb1 cb2
-- The following Iterate*E functions generated by toold/GenEitherTypes.hs
compileProcedure (IterateUnitUnitE iv bf) = do
    i <- nextBind
    let bi = RemBindUnit i
    j <- nextBind
    let bj = RemBindUnit j
    _ <- compileIterateProcedure UnitType UnitType i bi j bj iv bf
    return bj
compileProcedure (IterateUnitBoolE iv bf) = do
    i <- nextBind
    let bi = RemBindUnit i
    j <- nextBind
    let bj = RemBindB j
    _ <- compileIterateProcedure UnitType BoolType i bi j bj iv bf
    return bj
compileProcedure (IterateUnitW8E iv bf) = do
    i <- nextBind
    let bi = RemBindUnit i
    j <- nextBind
    let bj = RemBindW8 j
    _ <- compileIterateProcedure UnitType Word8Type i bi j bj iv bf
    return bj
compileProcedure (IterateUnitW16E iv bf) = do
    i <- nextBind
    let bi = RemBindUnit i
    j <- nextBind
    let bj = RemBindW16 j
    _ <- compileIterateProcedure UnitType Word16Type i bi j bj iv bf
    return bj
compileProcedure (IterateUnitW32E iv bf) = do
    i <- nextBind
    let bi = RemBindUnit i
    j <- nextBind
    let bj = RemBindW32 j
    _ <- compileIterateProcedure UnitType Word32Type i bi j bj iv bf
    return bj
compileProcedure (IterateUnitI8E iv bf) = do
    i <- nextBind
    let bi = RemBindUnit i
    j <- nextBind
    let bj = RemBindI8 j
    _ <- compileIterateProcedure UnitType Int8Type i bi j bj iv bf
    return bj
compileProcedure (IterateUnitI16E iv bf) = do
    i <- nextBind
    let bi = RemBindUnit i
    j <- nextBind
    let bj = RemBindI16 j
    _ <- compileIterateProcedure UnitType Int16Type i bi j bj iv bf
    return bj
compileProcedure (IterateUnitI32E iv bf) = do
    i <- nextBind
    let bi = RemBindUnit i
    j <- nextBind
    let bj = RemBindI32 j
    _ <- compileIterateProcedure UnitType Int32Type i bi j bj iv bf
    return bj
compileProcedure (IterateUnitIE iv bf) = do
    i <- nextBind
    let bi = RemBindUnit i
    j <- nextBind
    let bj = RemBindI j
    _ <- compileIterateProcedure UnitType IntType i bi j bj iv bf
    return bj
compileProcedure (IterateUnitL8E iv bf) = do
    i <- nextBind
    let bi = RemBindUnit i
    j <- nextBind
    let bj = RemBindList8 j
    _ <- compileIterateProcedure UnitType List8Type i bi j bj iv bf
    return bj
compileProcedure (IterateUnitFloatE iv bf) = do
    i <- nextBind
    let bi = RemBindUnit i
    j <- nextBind
    let bj = RemBindFloat j
    _ <- compileIterateProcedure UnitType FloatType i bi j bj iv bf
    return bj
compileProcedure (IterateBoolUnitE iv bf) = do
    i <- nextBind
    let bi = RemBindB i
    j <- nextBind
    let bj = RemBindUnit j
    _ <- compileIterateProcedure BoolType UnitType i bi j bj iv bf
    return bj
compileProcedure (IterateBoolBoolE iv bf) = do
    i <- nextBind
    let bi = RemBindB i
    j <- nextBind
    let bj = RemBindB j
    _ <- compileIterateProcedure BoolType BoolType i bi j bj iv bf
    return bj
compileProcedure (IterateBoolW8E iv bf) = do
    i <- nextBind
    let bi = RemBindB i
    j <- nextBind
    let bj = RemBindW8 j
    _ <- compileIterateProcedure BoolType Word8Type i bi j bj iv bf
    return bj
compileProcedure (IterateBoolW16E iv bf) = do
    i <- nextBind
    let bi = RemBindB i
    j <- nextBind
    let bj = RemBindW16 j
    _ <- compileIterateProcedure BoolType Word16Type i bi j bj iv bf
    return bj
compileProcedure (IterateBoolW32E iv bf) = do
    i <- nextBind
    let bi = RemBindB i
    j <- nextBind
    let bj = RemBindW32 j
    _ <- compileIterateProcedure BoolType Word32Type i bi j bj iv bf
    return bj
compileProcedure (IterateBoolI8E iv bf) = do
    i <- nextBind
    let bi = RemBindB i
    j <- nextBind
    let bj = RemBindI8 j
    _ <- compileIterateProcedure BoolType Int8Type i bi j bj iv bf
    return bj
compileProcedure (IterateBoolI16E iv bf) = do
    i <- nextBind
    let bi = RemBindB i
    j <- nextBind
    let bj = RemBindI16 j
    _ <- compileIterateProcedure BoolType Int16Type i bi j bj iv bf
    return bj
compileProcedure (IterateBoolI32E iv bf) = do
    i <- nextBind
    let bi = RemBindB i
    j <- nextBind
    let bj = RemBindI32 j
    _ <- compileIterateProcedure BoolType Int32Type i bi j bj iv bf
    return bj
compileProcedure (IterateBoolIE iv bf) = do
    i <- nextBind
    let bi = RemBindB i
    j <- nextBind
    let bj = RemBindI j
    _ <- compileIterateProcedure BoolType IntType i bi j bj iv bf
    return bj
compileProcedure (IterateBoolL8E iv bf) = do
    i <- nextBind
    let bi = RemBindB i
    j <- nextBind
    let bj = RemBindList8 j
    _ <- compileIterateProcedure BoolType List8Type i bi j bj iv bf
    return bj
compileProcedure (IterateBoolFloatE iv bf) = do
    i <- nextBind
    let bi = RemBindB i
    j <- nextBind
    let bj = RemBindFloat j
    _ <- compileIterateProcedure BoolType FloatType i bi j bj iv bf
    return bj
compileProcedure (IterateW8UnitE iv bf) = do
    i <- nextBind
    let bi = RemBindW8 i
    j <- nextBind
    let bj = RemBindUnit j
    _ <- compileIterateProcedure Word8Type UnitType i bi j bj iv bf
    return bj
compileProcedure (IterateW8BoolE iv bf) = do
    i <- nextBind
    let bi = RemBindW8 i
    j <- nextBind
    let bj = RemBindB j
    _ <- compileIterateProcedure Word8Type BoolType i bi j bj iv bf
    return bj
compileProcedure (IterateW8W8E iv bf) = do
    i <- nextBind
    let bi = RemBindW8 i
    j <- nextBind
    let bj = RemBindW8 j
    _ <- compileIterateProcedure Word8Type Word8Type i bi j bj iv bf
    return bj
compileProcedure (IterateW8W16E iv bf) = do
    i <- nextBind
    let bi = RemBindW8 i
    j <- nextBind
    let bj = RemBindW16 j
    _ <- compileIterateProcedure Word8Type Word16Type i bi j bj iv bf
    return bj
compileProcedure (IterateW8W32E iv bf) = do
    i <- nextBind
    let bi = RemBindW8 i
    j <- nextBind
    let bj = RemBindW32 j
    _ <- compileIterateProcedure Word8Type Word32Type i bi j bj iv bf
    return bj
compileProcedure (IterateW8I8E iv bf) = do
    i <- nextBind
    let bi = RemBindW8 i
    j <- nextBind
    let bj = RemBindI8 j
    _ <- compileIterateProcedure Word8Type Int8Type i bi j bj iv bf
    return bj
compileProcedure (IterateW8I16E iv bf) = do
    i <- nextBind
    let bi = RemBindW8 i
    j <- nextBind
    let bj = RemBindI16 j
    _ <- compileIterateProcedure Word8Type Int16Type i bi j bj iv bf
    return bj
compileProcedure (IterateW8I32E iv bf) = do
    i <- nextBind
    let bi = RemBindW8 i
    j <- nextBind
    let bj = RemBindI32 j
    _ <- compileIterateProcedure Word8Type Int32Type i bi j bj iv bf
    return bj
compileProcedure (IterateW8IE iv bf) = do
    i <- nextBind
    let bi = RemBindW8 i
    j <- nextBind
    let bj = RemBindI j
    _ <- compileIterateProcedure Word8Type IntType i bi j bj iv bf
    return bj
compileProcedure (IterateW8L8E iv bf) = do
    i <- nextBind
    let bi = RemBindW8 i
    j <- nextBind
    let bj = RemBindList8 j
    _ <- compileIterateProcedure Word8Type List8Type i bi j bj iv bf
    return bj
compileProcedure (IterateW8FloatE iv bf) = do
    i <- nextBind
    let bi = RemBindW8 i
    j <- nextBind
    let bj = RemBindFloat j
    _ <- compileIterateProcedure Word8Type FloatType i bi j bj iv bf
    return bj
compileProcedure (IterateW16UnitE iv bf) = do
    i <- nextBind
    let bi = RemBindW16 i
    j <- nextBind
    let bj = RemBindUnit j
    _ <- compileIterateProcedure Word16Type UnitType i bi j bj iv bf
    return bj
compileProcedure (IterateW16BoolE iv bf) = do
    i <- nextBind
    let bi = RemBindW16 i
    j <- nextBind
    let bj = RemBindB j
    _ <- compileIterateProcedure Word16Type BoolType i bi j bj iv bf
    return bj
compileProcedure (IterateW16W8E iv bf) = do
    i <- nextBind
    let bi = RemBindW16 i
    j <- nextBind
    let bj = RemBindW8 j
    _ <- compileIterateProcedure Word16Type Word8Type i bi j bj iv bf
    return bj
compileProcedure (IterateW16W16E iv bf) = do
    i <- nextBind
    let bi = RemBindW16 i
    j <- nextBind
    let bj = RemBindW16 j
    _ <- compileIterateProcedure Word16Type Word16Type i bi j bj iv bf
    return bj
compileProcedure (IterateW16W32E iv bf) = do
    i <- nextBind
    let bi = RemBindW16 i
    j <- nextBind
    let bj = RemBindW32 j
    _ <- compileIterateProcedure Word16Type Word32Type i bi j bj iv bf
    return bj
compileProcedure (IterateW16I8E iv bf) = do
    i <- nextBind
    let bi = RemBindW16 i
    j <- nextBind
    let bj = RemBindI8 j
    _ <- compileIterateProcedure Word16Type Int8Type i bi j bj iv bf
    return bj
compileProcedure (IterateW16I16E iv bf) = do
    i <- nextBind
    let bi = RemBindW16 i
    j <- nextBind
    let bj = RemBindI16 j
    _ <- compileIterateProcedure Word16Type Int16Type i bi j bj iv bf
    return bj
compileProcedure (IterateW16I32E iv bf) = do
    i <- nextBind
    let bi = RemBindW16 i
    j <- nextBind
    let bj = RemBindI32 j
    _ <- compileIterateProcedure Word16Type Int32Type i bi j bj iv bf
    return bj
compileProcedure (IterateW16IE iv bf) = do
    i <- nextBind
    let bi = RemBindW16 i
    j <- nextBind
    let bj = RemBindI j
    _ <- compileIterateProcedure Word16Type IntType i bi j bj iv bf
    return bj
compileProcedure (IterateW16L8E iv bf) = do
    i <- nextBind
    let bi = RemBindW16 i
    j <- nextBind
    let bj = RemBindList8 j
    _ <- compileIterateProcedure Word16Type List8Type i bi j bj iv bf
    return bj
compileProcedure (IterateW16FloatE iv bf) = do
    i <- nextBind
    let bi = RemBindW16 i
    j <- nextBind
    let bj = RemBindFloat j
    _ <- compileIterateProcedure Word16Type FloatType i bi j bj iv bf
    return bj
compileProcedure (IterateW32UnitE iv bf) = do
    i <- nextBind
    let bi = RemBindW32 i
    j <- nextBind
    let bj = RemBindUnit j
    _ <- compileIterateProcedure Word32Type UnitType i bi j bj iv bf
    return bj
compileProcedure (IterateW32BoolE iv bf) = do
    i <- nextBind
    let bi = RemBindW32 i
    j <- nextBind
    let bj = RemBindB j
    _ <- compileIterateProcedure Word32Type BoolType i bi j bj iv bf
    return bj
compileProcedure (IterateW32W8E iv bf) = do
    i <- nextBind
    let bi = RemBindW32 i
    j <- nextBind
    let bj = RemBindW8 j
    _ <- compileIterateProcedure Word32Type Word8Type i bi j bj iv bf
    return bj
compileProcedure (IterateW32W16E iv bf) = do
    i <- nextBind
    let bi = RemBindW32 i
    j <- nextBind
    let bj = RemBindW16 j
    _ <- compileIterateProcedure Word32Type Word16Type i bi j bj iv bf
    return bj
compileProcedure (IterateW32W32E iv bf) = do
    i <- nextBind
    let bi = RemBindW32 i
    j <- nextBind
    let bj = RemBindW32 j
    _ <- compileIterateProcedure Word32Type Word32Type i bi j bj iv bf
    return bj
compileProcedure (IterateW32I8E iv bf) = do
    i <- nextBind
    let bi = RemBindW32 i
    j <- nextBind
    let bj = RemBindI8 j
    _ <- compileIterateProcedure Word32Type Int8Type i bi j bj iv bf
    return bj
compileProcedure (IterateW32I16E iv bf) = do
    i <- nextBind
    let bi = RemBindW32 i
    j <- nextBind
    let bj = RemBindI16 j
    _ <- compileIterateProcedure Word32Type Int16Type i bi j bj iv bf
    return bj
compileProcedure (IterateW32I32E iv bf) = do
    i <- nextBind
    let bi = RemBindW32 i
    j <- nextBind
    let bj = RemBindI32 j
    _ <- compileIterateProcedure Word32Type Int32Type i bi j bj iv bf
    return bj
compileProcedure (IterateW32IE iv bf) = do
    i <- nextBind
    let bi = RemBindW32 i
    j <- nextBind
    let bj = RemBindI j
    _ <- compileIterateProcedure Word32Type IntType i bi j bj iv bf
    return bj
compileProcedure (IterateW32L8E iv bf) = do
    i <- nextBind
    let bi = RemBindW32 i
    j <- nextBind
    let bj = RemBindList8 j
    _ <- compileIterateProcedure Word32Type List8Type i bi j bj iv bf
    return bj
compileProcedure (IterateW32FloatE iv bf) = do
    i <- nextBind
    let bi = RemBindW32 i
    j <- nextBind
    let bj = RemBindFloat j
    _ <- compileIterateProcedure Word32Type FloatType i bi j bj iv bf
    return bj
compileProcedure (IterateI8UnitE iv bf) = do
    i <- nextBind
    let bi = RemBindI8 i
    j <- nextBind
    let bj = RemBindUnit j
    _ <- compileIterateProcedure Int8Type UnitType i bi j bj iv bf
    return bj
compileProcedure (IterateI8BoolE iv bf) = do
    i <- nextBind
    let bi = RemBindI8 i
    j <- nextBind
    let bj = RemBindB j
    _ <- compileIterateProcedure Int8Type BoolType i bi j bj iv bf
    return bj
compileProcedure (IterateI8W8E iv bf) = do
    i <- nextBind
    let bi = RemBindI8 i
    j <- nextBind
    let bj = RemBindW8 j
    _ <- compileIterateProcedure Int8Type Word8Type i bi j bj iv bf
    return bj
compileProcedure (IterateI8W16E iv bf) = do
    i <- nextBind
    let bi = RemBindI8 i
    j <- nextBind
    let bj = RemBindW16 j
    _ <- compileIterateProcedure Int8Type Word16Type i bi j bj iv bf
    return bj
compileProcedure (IterateI8W32E iv bf) = do
    i <- nextBind
    let bi = RemBindI8 i
    j <- nextBind
    let bj = RemBindW32 j
    _ <- compileIterateProcedure Int8Type Word32Type i bi j bj iv bf
    return bj
compileProcedure (IterateI8I8E iv bf) = do
    i <- nextBind
    let bi = RemBindI8 i
    j <- nextBind
    let bj = RemBindI8 j
    _ <- compileIterateProcedure Int8Type Int8Type i bi j bj iv bf
    return bj
compileProcedure (IterateI8I16E iv bf) = do
    i <- nextBind
    let bi = RemBindI8 i
    j <- nextBind
    let bj = RemBindI16 j
    _ <- compileIterateProcedure Int8Type Int16Type i bi j bj iv bf
    return bj
compileProcedure (IterateI8I32E iv bf) = do
    i <- nextBind
    let bi = RemBindI8 i
    j <- nextBind
    let bj = RemBindI32 j
    _ <- compileIterateProcedure Int8Type Int32Type i bi j bj iv bf
    return bj
compileProcedure (IterateI8IE iv bf) = do
    i <- nextBind
    let bi = RemBindI8 i
    j <- nextBind
    let bj = RemBindI j
    _ <- compileIterateProcedure Int8Type IntType i bi j bj iv bf
    return bj
compileProcedure (IterateI8L8E iv bf) = do
    i <- nextBind
    let bi = RemBindI8 i
    j <- nextBind
    let bj = RemBindList8 j
    _ <- compileIterateProcedure Int8Type List8Type i bi j bj iv bf
    return bj
compileProcedure (IterateI8FloatE iv bf) = do
    i <- nextBind
    let bi = RemBindI8 i
    j <- nextBind
    let bj = RemBindFloat j
    _ <- compileIterateProcedure Int8Type FloatType i bi j bj iv bf
    return bj
compileProcedure (IterateI16UnitE iv bf) = do
    i <- nextBind
    let bi = RemBindI16 i
    j <- nextBind
    let bj = RemBindUnit j
    _ <- compileIterateProcedure Int16Type UnitType i bi j bj iv bf
    return bj
compileProcedure (IterateI16BoolE iv bf) = do
    i <- nextBind
    let bi = RemBindI16 i
    j <- nextBind
    let bj = RemBindB j
    _ <- compileIterateProcedure Int16Type BoolType i bi j bj iv bf
    return bj
compileProcedure (IterateI16W8E iv bf) = do
    i <- nextBind
    let bi = RemBindI16 i
    j <- nextBind
    let bj = RemBindW8 j
    _ <- compileIterateProcedure Int16Type Word8Type i bi j bj iv bf
    return bj
compileProcedure (IterateI16W16E iv bf) = do
    i <- nextBind
    let bi = RemBindI16 i
    j <- nextBind
    let bj = RemBindW16 j
    _ <- compileIterateProcedure Int16Type Word16Type i bi j bj iv bf
    return bj
compileProcedure (IterateI16W32E iv bf) = do
    i <- nextBind
    let bi = RemBindI16 i
    j <- nextBind
    let bj = RemBindW32 j
    _ <- compileIterateProcedure Int16Type Word32Type i bi j bj iv bf
    return bj
compileProcedure (IterateI16I8E iv bf) = do
    i <- nextBind
    let bi = RemBindI16 i
    j <- nextBind
    let bj = RemBindI8 j
    _ <- compileIterateProcedure Int16Type Int8Type i bi j bj iv bf
    return bj
compileProcedure (IterateI16I16E iv bf) = do
    i <- nextBind
    let bi = RemBindI16 i
    j <- nextBind
    let bj = RemBindI16 j
    _ <- compileIterateProcedure Int16Type Int16Type i bi j bj iv bf
    return bj
compileProcedure (IterateI16I32E iv bf) = do
    i <- nextBind
    let bi = RemBindI16 i
    j <- nextBind
    let bj = RemBindI32 j
    _ <- compileIterateProcedure Int16Type Int32Type i bi j bj iv bf
    return bj
compileProcedure (IterateI16IE iv bf) = do
    i <- nextBind
    let bi = RemBindI16 i
    j <- nextBind
    let bj = RemBindI j
    _ <- compileIterateProcedure Int16Type IntType i bi j bj iv bf
    return bj
compileProcedure (IterateI16L8E iv bf) = do
    i <- nextBind
    let bi = RemBindI16 i
    j <- nextBind
    let bj = RemBindList8 j
    _ <- compileIterateProcedure Int16Type List8Type i bi j bj iv bf
    return bj
compileProcedure (IterateI16FloatE iv bf) = do
    i <- nextBind
    let bi = RemBindI16 i
    j <- nextBind
    let bj = RemBindFloat j
    _ <- compileIterateProcedure Int16Type FloatType i bi j bj iv bf
    return bj
compileProcedure (IterateI32UnitE iv bf) = do
    i <- nextBind
    let bi = RemBindI32 i
    j <- nextBind
    let bj = RemBindUnit j
    _ <- compileIterateProcedure Int32Type UnitType i bi j bj iv bf
    return bj
compileProcedure (IterateI32BoolE iv bf) = do
    i <- nextBind
    let bi = RemBindI32 i
    j <- nextBind
    let bj = RemBindB j
    _ <- compileIterateProcedure Int32Type BoolType i bi j bj iv bf
    return bj
compileProcedure (IterateI32W8E iv bf) = do
    i <- nextBind
    let bi = RemBindI32 i
    j <- nextBind
    let bj = RemBindW8 j
    _ <- compileIterateProcedure Int32Type Word8Type i bi j bj iv bf
    return bj
compileProcedure (IterateI32W16E iv bf) = do
    i <- nextBind
    let bi = RemBindI32 i
    j <- nextBind
    let bj = RemBindW16 j
    _ <- compileIterateProcedure Int32Type Word16Type i bi j bj iv bf
    return bj
compileProcedure (IterateI32W32E iv bf) = do
    i <- nextBind
    let bi = RemBindI32 i
    j <- nextBind
    let bj = RemBindW32 j
    _ <- compileIterateProcedure Int32Type Word32Type i bi j bj iv bf
    return bj
compileProcedure (IterateI32I8E iv bf) = do
    i <- nextBind
    let bi = RemBindI32 i
    j <- nextBind
    let bj = RemBindI8 j
    _ <- compileIterateProcedure Int32Type Int8Type i bi j bj iv bf
    return bj
compileProcedure (IterateI32I16E iv bf) = do
    i <- nextBind
    let bi = RemBindI32 i
    j <- nextBind
    let bj = RemBindI16 j
    _ <- compileIterateProcedure Int32Type Int16Type i bi j bj iv bf
    return bj
compileProcedure (IterateI32I32E iv bf) = do
    i <- nextBind
    let bi = RemBindI32 i
    j <- nextBind
    let bj = RemBindI32 j
    _ <- compileIterateProcedure Int32Type Int32Type i bi j bj iv bf
    return bj
compileProcedure (IterateI32IE iv bf) = do
    i <- nextBind
    let bi = RemBindI32 i
    j <- nextBind
    let bj = RemBindI j
    _ <- compileIterateProcedure Int32Type IntType i bi j bj iv bf
    return bj
compileProcedure (IterateI32L8E iv bf) = do
    i <- nextBind
    let bi = RemBindI32 i
    j <- nextBind
    let bj = RemBindList8 j
    _ <- compileIterateProcedure Int32Type List8Type i bi j bj iv bf
    return bj
compileProcedure (IterateI32FloatE iv bf) = do
    i <- nextBind
    let bi = RemBindI32 i
    j <- nextBind
    let bj = RemBindFloat j
    _ <- compileIterateProcedure Int32Type FloatType i bi j bj iv bf
    return bj
compileProcedure (IterateIUnitE iv bf) = do
    i <- nextBind
    let bi = RemBindI i
    j <- nextBind
    let bj = RemBindUnit j
    _ <- compileIterateProcedure IntType UnitType i bi j bj iv bf
    return bj
compileProcedure (IterateIBoolE iv bf) = do
    i <- nextBind
    let bi = RemBindI i
    j <- nextBind
    let bj = RemBindB j
    _ <- compileIterateProcedure IntType BoolType i bi j bj iv bf
    return bj
compileProcedure (IterateIW8E iv bf) = do
    i <- nextBind
    let bi = RemBindI i
    j <- nextBind
    let bj = RemBindW8 j
    _ <- compileIterateProcedure IntType Word8Type i bi j bj iv bf
    return bj
compileProcedure (IterateIW16E iv bf) = do
    i <- nextBind
    let bi = RemBindI i
    j <- nextBind
    let bj = RemBindW16 j
    _ <- compileIterateProcedure IntType Word16Type i bi j bj iv bf
    return bj
compileProcedure (IterateIW32E iv bf) = do
    i <- nextBind
    let bi = RemBindI i
    j <- nextBind
    let bj = RemBindW32 j
    _ <- compileIterateProcedure IntType Word32Type i bi j bj iv bf
    return bj
compileProcedure (IterateII8E iv bf) = do
    i <- nextBind
    let bi = RemBindI i
    j <- nextBind
    let bj = RemBindI8 j
    _ <- compileIterateProcedure IntType Int8Type i bi j bj iv bf
    return bj
compileProcedure (IterateII16E iv bf) = do
    i <- nextBind
    let bi = RemBindI i
    j <- nextBind
    let bj = RemBindI16 j
    _ <- compileIterateProcedure IntType Int16Type i bi j bj iv bf
    return bj
compileProcedure (IterateII32E iv bf) = do
    i <- nextBind
    let bi = RemBindI i
    j <- nextBind
    let bj = RemBindI32 j
    _ <- compileIterateProcedure IntType Int32Type i bi j bj iv bf
    return bj
compileProcedure (IterateIIE iv bf) = do
    i <- nextBind
    let bi = RemBindI i
    j <- nextBind
    let bj = RemBindI j
    _ <- compileIterateProcedure IntType IntType i bi j bj iv bf
    return bj
compileProcedure (IterateIL8E iv bf) = do
    i <- nextBind
    let bi = RemBindI i
    j <- nextBind
    let bj = RemBindList8 j
    _ <- compileIterateProcedure IntType List8Type i bi j bj iv bf
    return bj
compileProcedure (IterateIFloatE iv bf) = do
    i <- nextBind
    let bi = RemBindI i
    j <- nextBind
    let bj = RemBindFloat j
    _ <- compileIterateProcedure IntType FloatType i bi j bj iv bf
    return bj
compileProcedure (IterateL8UnitE iv bf) = do
    i <- nextBind
    let bi = RemBindList8 i
    j <- nextBind
    let bj = RemBindUnit j
    _ <- compileIterateProcedure List8Type UnitType i bi j bj iv bf
    return bj
compileProcedure (IterateL8BoolE iv bf) = do
    i <- nextBind
    let bi = RemBindList8 i
    j <- nextBind
    let bj = RemBindB j
    _ <- compileIterateProcedure List8Type BoolType i bi j bj iv bf
    return bj
compileProcedure (IterateL8W8E iv bf) = do
    i <- nextBind
    let bi = RemBindList8 i
    j <- nextBind
    let bj = RemBindW8 j
    _ <- compileIterateProcedure List8Type Word8Type i bi j bj iv bf
    return bj
compileProcedure (IterateL8W16E iv bf) = do
    i <- nextBind
    let bi = RemBindList8 i
    j <- nextBind
    let bj = RemBindW16 j
    _ <- compileIterateProcedure List8Type Word16Type i bi j bj iv bf
    return bj
compileProcedure (IterateL8W32E iv bf) = do
    i <- nextBind
    let bi = RemBindList8 i
    j <- nextBind
    let bj = RemBindW32 j
    _ <- compileIterateProcedure List8Type Word32Type i bi j bj iv bf
    return bj
compileProcedure (IterateL8I8E iv bf) = do
    i <- nextBind
    let bi = RemBindList8 i
    j <- nextBind
    let bj = RemBindI8 j
    _ <- compileIterateProcedure List8Type Int8Type i bi j bj iv bf
    return bj
compileProcedure (IterateL8I16E iv bf) = do
    i <- nextBind
    let bi = RemBindList8 i
    j <- nextBind
    let bj = RemBindI16 j
    _ <- compileIterateProcedure List8Type Int16Type i bi j bj iv bf
    return bj
compileProcedure (IterateL8I32E iv bf) = do
    i <- nextBind
    let bi = RemBindList8 i
    j <- nextBind
    let bj = RemBindI32 j
    _ <- compileIterateProcedure List8Type Int32Type i bi j bj iv bf
    return bj
compileProcedure (IterateL8IE iv bf) = do
    i <- nextBind
    let bi = RemBindList8 i
    j <- nextBind
    let bj = RemBindI j
    _ <- compileIterateProcedure List8Type IntType i bi j bj iv bf
    return bj
compileProcedure (IterateL8L8E iv bf) = do
    i <- nextBind
    let bi = RemBindList8 i
    j <- nextBind
    let bj = RemBindList8 j
    _ <- compileIterateProcedure List8Type List8Type i bi j bj iv bf
    return bj
compileProcedure (IterateL8FloatE iv bf) = do
    i <- nextBind
    let bi = RemBindList8 i
    j <- nextBind
    let bj = RemBindFloat j
    _ <- compileIterateProcedure List8Type FloatType i bi j bj iv bf
    return bj
compileProcedure (IterateFloatUnitE iv bf) = do
    i <- nextBind
    let bi = RemBindFloat i
    j <- nextBind
    let bj = RemBindUnit j
    _ <- compileIterateProcedure FloatType UnitType i bi j bj iv bf
    return bj
compileProcedure (IterateFloatBoolE iv bf) = do
    i <- nextBind
    let bi = RemBindFloat i
    j <- nextBind
    let bj = RemBindB j
    _ <- compileIterateProcedure FloatType BoolType i bi j bj iv bf
    return bj
compileProcedure (IterateFloatW8E iv bf) = do
    i <- nextBind
    let bi = RemBindFloat i
    j <- nextBind
    let bj = RemBindW8 j
    _ <- compileIterateProcedure FloatType Word8Type i bi j bj iv bf
    return bj
compileProcedure (IterateFloatW16E iv bf) = do
    i <- nextBind
    let bi = RemBindFloat i
    j <- nextBind
    let bj = RemBindW16 j
    _ <- compileIterateProcedure FloatType Word16Type i bi j bj iv bf
    return bj
compileProcedure (IterateFloatW32E iv bf) = do
    i <- nextBind
    let bi = RemBindFloat i
    j <- nextBind
    let bj = RemBindW32 j
    _ <- compileIterateProcedure FloatType Word32Type i bi j bj iv bf
    return bj
compileProcedure (IterateFloatI8E iv bf) = do
    i <- nextBind
    let bi = RemBindFloat i
    j <- nextBind
    let bj = RemBindI8 j
    _ <- compileIterateProcedure FloatType Int8Type i bi j bj iv bf
    return bj
compileProcedure (IterateFloatI16E iv bf) = do
    i <- nextBind
    let bi = RemBindFloat i
    j <- nextBind
    let bj = RemBindI16 j
    _ <- compileIterateProcedure FloatType Int16Type i bi j bj iv bf
    return bj
compileProcedure (IterateFloatI32E iv bf) = do
    i <- nextBind
    let bi = RemBindFloat i
    j <- nextBind
    let bj = RemBindI32 j
    _ <- compileIterateProcedure FloatType Int32Type i bi j bj iv bf
    return bj
compileProcedure (IterateFloatIE iv bf) = do
    i <- nextBind
    let bi = RemBindFloat i
    j <- nextBind
    let bj = RemBindI j
    _ <- compileIterateProcedure FloatType IntType i bi j bj iv bf
    return bj
compileProcedure (IterateFloatL8E iv bf) = do
    i <- nextBind
    let bi = RemBindFloat i
    j <- nextBind
    let bj = RemBindList8 j
    _ <- compileIterateProcedure FloatType List8Type i bi j bj iv bf
    return bj
compileProcedure (IterateFloatFloatE iv bf) = do
    i <- nextBind
    let bi = RemBindFloat i
    j <- nextBind
    let bj = RemBindFloat j
    _ <- compileIterateProcedure FloatType FloatType i bi j bj iv bf
    return bj
compileProcedure (AppLambdaUnit n m) = compileAppLambdaProcedure n UnitType RemBindUnit m
compileProcedure (AppLambdaWord8 n m) = compileAppLambdaProcedure n Word8Type RemBindW8 m
compileProcedure (LamExprWord8Unit _ _) = error "Crap1"
compileProcedure (AppExprWord8Unit _ _) = error "Crap2"
compileProcedure _ = error "compileProcedure - Unknown procedure, it may actually be a command"

compileIfThenElseProcedure :: ExprB a => CompileType -> Expr Bool -> Arduino (Expr a) -> Arduino (Expr a) -> State CompileState (Expr a)
compileIfThenElseProcedure t e cb1 cb2 = do
    s <- get
    let b = ib s
    put s {ib = b + 1}
    _ <- if t == UnitType
         then return LitUnit
         else compileAllocBind $ compileTypeToString t ++ " " ++ bindName ++ show b ++ ";"
    ce <- compileExpr e
    _ <- compileLine $ "if (" ++ ce ++ ")"
    r1 <- compileCodeBlock True "" cb1
    _ <- if t == UnitType
         then return LitUnit
         else do
           cr1 <- compileExpr r1
           compileLineIndent $ bindName ++ show b ++ " = " ++ cr1 ++ ";"
    _ <- compileLineIndent "}"
    _ <- compileLine "else"
    r2 <- compileCodeBlock True "" cb2
    _ <- if t == UnitType
         then return LitUnit
         else do
           cr2 <- compileExpr r2
           compileLineIndent $ bindName ++ show b ++ " = " ++ cr2 ++ ";"
    _ <- compileLineIndent "}"
    return $ remBind b

compileIfThenElseEitherProcedure :: (ExprB a, ExprB b) => CompileType -> CompileType -> Expr Bool -> Arduino (ExprEither a b) -> Arduino (ExprEither a b) -> State CompileState (ExprEither a b)
compileIfThenElseEitherProcedure t1 t2 e cb1 cb2 = do
    s <- get
    let ibs = head $ iterBinds s
    ce <- compileExpr e
    _ <- compileLine $ "if (" ++ ce ++ ")"
    r1 <- compileCodeBlock True "" cb1
    _ <- case r1 of
            ExprLeft a -> do
                if t1 == UnitType then return LitUnit
                else if t1 == List8Type then do
                  ca <- compileExpr a
                  compileLineIndent $ "listAssign(&" ++ bindName ++ show (fst ibs) ++ ", " ++ ca ++ ");"
                else do
                  ca <- compileExpr a
                  compileLineIndent $ bindName ++ show (fst ibs) ++ " = " ++ ca ++ ";"
            ExprRight b -> do
                _ <- if t2 == UnitType then return LitUnit
                     else if t2 == List8Type then do
                       cb <- compileExpr b
                       compileLineIndent $ "listAssign(&" ++ bindName ++ show (snd ibs) ++ ", " ++ cb ++ ");"
                     else do
                       cb <- compileExpr b
                       compileLineIndent $ bindName ++ show (snd ibs) ++ " = " ++ cb ++ ";"
                compileLineIndent "break;"
    _ <- compileLineIndent "}"
    _ <- compileLine "else"
    r2 <- compileCodeBlock True "" cb2
    _ <- case r2 of
            ExprLeft a -> do
                if (t1 == UnitType) then return LitUnit
                else if t1 == List8Type then do
                  ca <- compileExpr a
                  compileLineIndent $ "listAssign(&" ++ bindName ++ show (fst ibs) ++ ", " ++ ca ++ ");"
                else do
                  ca <- compileExpr a
                  compileLineIndent $ bindName ++ show (fst ibs) ++ " = " ++ ca ++ ";"
            ExprRight b -> do
                _ <- if (t2 == UnitType) then return LitUnit
                     else if t2 == List8Type then do
                       cb <- compileExpr b
                       compileLineIndent $ "listAssign(&" ++ bindName ++ show (snd ibs) ++ ", " ++ cb ++ ");"
                     else do
                       cb <- compileExpr b
                       compileLineIndent $ bindName ++ show (snd ibs) ++ " = " ++ cb ++ ";"
                compileLineIndent "break;"
    _ <- compileLineIndent "}"
    return $ r2

compileIterateProcedure :: (ExprB a, ExprB b) => CompileType -> CompileType ->
                           Int -> Expr a -> Int -> Expr b -> Expr a ->
                           (Expr a -> Arduino(ExprEither a b)) -> State CompileState (Expr b)
compileIterateProcedure ta tb b1 b1e b2 b2e iv bf = do
    s <- get
    put s {iterBinds = (b1, b2):iterBinds s}
    _ <- if ta == UnitType
         then return LitUnit
         else compileAllocBind $ compileTypeToString ta ++ " " ++ bindName ++ show b1 ++ ";"
    _ <- if tb == UnitType
         then return LitUnit
         else compileAllocBind $ compileTypeToString tb ++ " " ++ bindName ++ show b2 ++ ";"
    _ <- if ta == List8Type
         then do
           civ <- compileExpr iv
           compileLine $ "listAssign(&" ++ bindName ++ show b1 ++ ", " ++ civ ++ ");"
         else if ta == UnitType
              then return LitUnit
              else do
                civ <- compileExpr iv
                compileLine $ bindName ++ show b1 ++ " = " ++ civ ++ ";"
    _ <- compileCodeBlock False "while (1)\n" $ bf b1e
    _ <- compileLineIndent "}"
    s' <- get
    put s' {iterBinds = tail $ iterBinds s'}
    return b2e

compileAppLambdaProcedure :: ExprB a => String -> CompileType -> (Int -> Expr a) -> Arduino (Expr a) -> State CompileState (Expr a)
compileAppLambdaProcedure n t rb m = do
    s <- get
    let b = ib s
    put s {ib = b + 1}
    (body, args) <- compileArgs m
    _ <- compileLine $ bindName ++ show b ++ " = " ++ n ++ "(" ++ args ++ ");"
    _ <- compileAllocBind $ compileTypeToString t ++ " " ++ bindName ++ show b ++ ";"
    s' <- get
    let newFunc = (MkCompilable body, t, n)
    if not $ funcElemToDo n (funcsToDo s')
    then put s' {funcsToDo = newFunc : funcsToDo s'}
    else return ()
    return $ rb b

funcElemToDo :: String -> [(Compilable, CompileType, String)] -> Bool
funcElemToDo _ [] = False
funcElemToDo s (f:fs) = case f of
    (_, _, s') -> if s == s' then True else funcElemToDo s fs

compileArgs :: Arduino a -> State CompileState (Arduino a, String)
compileArgs (Arduino (T.Appl ( T.Primitive (AppExprWord8Unit m e)))) = do
    (func, string) <- compileArgs m
    ce <- compileExpr e
    return (func, ce ++ if null string then "" else ", " ++ string)
compileArgs (Arduino (T.Appl ( T.Primitive (AppExprWord8Word8 m e)))) = do
    (func, string) <- compileArgs m
    ce <- compileExpr e
    return (func, ce ++ if null string then "" else "," ++ string)
compileArgs m' = return (m', "")

compileCodeBlock :: Bool -> String -> Arduino a -> State CompileState a
compileCodeBlock bInside prelude (Arduino commands) = do
    s <- get
    put s {bindList = (binds s) : (bindList s),
           cmdList = (cmds s) : (cmdList s),
           binds = "",
           bindsInside = bInside : (bindsInside s),
           cmds = "",
           level = level s + 1 }
    r <- compileMonad commands
    s' <- get
    if bInside then
      put s' {bindList = tail $ bindList s',
             cmdList = tail $ cmdList s',
             binds = head $ bindList s',
             bindsInside = tail (bindsInside s'),
             cmds = (head $ cmdList s') ++ (indent $ level s') ++ "{\n" ++
                    body (binds s') (cmds s'),
             level = level s' - 1 }
    else
      put s' {bindList = tail $ bindList s',
             cmdList = tail $ cmdList s',
             binds = head $ bindList s',
             bindsInside = tail (bindsInside s'),
             cmds = (head $ cmdList s') ++
             binds s' ++
             (indent $ (level s') - 1) ++ prelude ++
             (indent $ level s') ++ "{\n" ++ (cmds s'),
             level = level s' - 1 }
    return r
  where
      body :: String -> String -> String
      body [] cs = cs
      body bs cs = bs ++ "\n" ++ cs

      compileMonad :: RemoteMonad ArduinoPrimitive a ->
                      State CompileState a
      compileMonad (T.Appl app) = compileAppl app
      compileMonad (T.Bind m k) = do
        r <- compileMonad m
        compileMonad (k r)
      compileMonad (T.Ap' m1 m2) = do
        f <- compileMonad m1
        g <- compileMonad m2
        return (f g)
      compileMonad (T.Alt' _ _)  = error "compileMonad: \"Alt\" not supported"
      compileMonad T.Empty'      = error "compileMonad: \"Empty\" not supported"
      compileMonad (T.Throw _)   = error "compileMonad: \"Throw\" not supported"
      compileMonad (T.Catch _ _) = error "compileMonad: \"Catch\" not supported"

      compileAppl :: RemoteApplicative ArduinoPrimitive a ->
                     State CompileState a
      compileAppl (T.Primitive p) = compilePrimitive p
      compileAppl (T.Ap a1 a2) = do
        f <- compileAppl a1
        g <- compileAppl a2
        return (f g)
      compileAppl (T.Pure a) = return a
      compileAppl (T.Alt _ _) = error "compileAppl: \"Alt\" not supported"
      compileAppl  T.Empty = error "compileAppl: \"Empty\" not supported"

compileSubExpr :: String -> Expr a -> State CompileState String
compileSubExpr ec e = do
  ce <- compileExpr e
  return $ ec ++ "(" ++ ce ++ ")"

compileTwoSubExpr :: String -> Expr a -> Expr b -> State CompileState String
compileTwoSubExpr ec e1 e2 = do
  ce1 <- compileExpr e1
  ce2 <- compileExpr e2
  return $ ec ++ "(" ++ ce1 ++ "," ++ ce2 ++ ")"

compileThreeSubExpr :: String -> Expr a -> Expr b -> Expr c -> State CompileState String
compileThreeSubExpr ec e1 e2 e3 = do
  ce1 <- compileExpr e1
  ce2 <- compileExpr e2
  ce3 <- compileExpr e3
  return $ ec ++ "(" ++ ce1 ++ "," ++ ce2 ++ "," ++ ce3 ++ ")"

compileInfixSubExpr :: String -> Expr a -> Expr b -> State CompileState String
compileInfixSubExpr ec e1 e2 = do
  ce1 <- compileExpr e1
  ce2 <- compileExpr e2
  return $ "(" ++ ce1 ++ " " ++ ec ++ " " ++ ce2 ++ ")"

compileSign :: Expr a -> State CompileState String
compileSign e = do
  ce <- compileExpr e
  return $ "(" ++ ce ++ " == 0 ? 0 : 1)"

compileIfSubExpr :: Expr a -> Expr b -> Expr b -> State CompileState String
compileIfSubExpr e1 e2 e3 = do
  ce1 <- compileExpr e1
  ce2 <- compileExpr e2
  ce3 <- compileExpr e3
  return $ ce1 ++ " ? " ++ ce2 ++ " : " ++ ce3

compileNeg :: Expr a -> State CompileState String
compileNeg = compileSubExpr "-"

compileComp :: Expr a -> State CompileState String
compileComp = compileSubExpr "~"

compileArg :: Int -> State CompileState String
compileArg b = return $ argName ++ show b

compileBind :: Int -> State CompileState String
compileBind b = return $ bindName ++ show b

compileBAnd :: Expr a -> Expr a -> State CompileState String
compileBAnd = compileInfixSubExpr "&&"

compileBOr :: Expr a -> Expr a -> State CompileState String
compileBOr = compileInfixSubExpr "||"

compileEqual :: Expr a -> Expr a -> State CompileState String
compileEqual = compileInfixSubExpr "=="

compileLess :: Expr a -> Expr a -> State CompileState String
compileLess = compileInfixSubExpr "<"

compileAdd :: Expr a -> Expr a -> State CompileState String
compileAdd = compileInfixSubExpr "+"

compileSub :: Expr a -> Expr a -> State CompileState String
compileSub = compileInfixSubExpr "-"

compileMult :: Expr a -> Expr a -> State CompileState String
compileMult = compileInfixSubExpr "*"

compileDiv :: Expr a -> Expr a -> State CompileState String
compileDiv = compileInfixSubExpr "/"

compileMod :: Expr a -> Expr a -> State CompileState String
compileMod = compileInfixSubExpr "%"

compileAnd :: Expr a -> Expr a -> State CompileState String
compileAnd = compileInfixSubExpr "&"

compileOr :: Expr a -> Expr a -> State CompileState String
compileOr = compileInfixSubExpr "|"

compileXor :: Expr a -> Expr a -> State CompileState String
compileXor = compileInfixSubExpr "^"

compileShiftLeft :: Expr a -> Expr b -> State CompileState String
compileShiftLeft = compileInfixSubExpr "<<"

compileShiftRight :: Expr a -> Expr b -> State CompileState String
compileShiftRight = compileInfixSubExpr ">>"

compileToInt :: Expr a -> State CompileState String
compileToInt e = do
  ce <- compileExpr e
  return $ "((int32_t) " ++ ce ++ ")"

compileFromInt :: String -> Expr a -> State CompileState String
compileFromInt t e = do
  ce <- compileExpr e
  return $ "((" ++ t ++ ") " ++ ce ++ ")"

compileRef :: Int -> State CompileState String
compileRef n = return $ refName ++ show n

compileExpr :: Expr a -> State CompileState String
compileExpr LitUnit = return "0"
compileExpr (ShowUnit _) = return $ show ()
compileExpr (RemArgUnit b) = compileArg b
compileExpr (RemBindUnit b) = compileBind b
compileExpr (LitB b) = return $ if b then "1" else "0"
compileExpr (ShowB e) = compileSubExpr "showBool" e
compileExpr (RefB n) = compileRef n
compileExpr (RemArgB b) = compileArg b
compileExpr (RemBindB b) = compileBind b
compileExpr (NotB e) = compileSubExpr "!" e
compileExpr (AndB e1 e2) = compileBAnd e1 e2
compileExpr (OrB e1 e2) = compileBOr e1 e2
compileExpr (EqB e1 e2) = compileEqual e1 e2
compileExpr (LessB e1 e2) = compileLess e1 e2
compileExpr (IfB e1 e2 e3) = compileIfSubExpr e1 e2 e3
compileExpr (EqW8 e1 e2) = compileEqual e1 e2
compileExpr (LessW8 e1 e2) = compileLess e1 e2
compileExpr (EqW16 e1 e2) = compileEqual e1 e2
compileExpr (LessW16 e1 e2) = compileLess e1 e2
compileExpr (EqW32 e1 e2) = compileEqual e1 e2
compileExpr (LessW32 e1 e2) = compileLess e1 e2
compileExpr (EqI8 e1 e2) = compileEqual e1 e2
compileExpr (LessI8 e1 e2) = compileLess e1 e2
compileExpr (EqI16 e1 e2) = compileEqual e1 e2
compileExpr (LessI16 e1 e2) = compileLess e1 e2
compileExpr (EqI32 e1 e2) = compileEqual e1 e2
compileExpr (LessI32 e1 e2) = compileLess e1 e2
compileExpr (EqI e1 e2) = compileEqual e1 e2
compileExpr (LessI e1 e2) = compileLess e1 e2
compileExpr (EqL8 e1 e2) = compileTwoSubExpr "list8Equal" e1 e2
compileExpr (LessL8 e1 e2) = compileTwoSubExpr "list8Less" e1 e2
compileExpr (EqFloat e1 e2) = compileEqual e1 e2
compileExpr (LessFloat e1 e2) = compileLess e1 e2
compileExpr (LitW8 w) = return $ show w
compileExpr (ShowW8 e) = compileSubExpr "showWord8" e
compileExpr (RefW8 n) = compileRef n
compileExpr (RemArgW8 b) = compileArg b
compileExpr (RemBindW8 b) = compileBind b
compileExpr (FromIntW8 e) = compileFromInt "uint8_t" e
compileExpr (ToIntW8 e) = compileToInt e
compileExpr (NegW8 e) = compileNeg e -- ToDo:  Check arduino compiler
compileExpr (SignW8 e) = compileSign e
compileExpr (AddW8 e1 e2) = compileAdd e1 e2
compileExpr (SubW8 e1 e2) = compileSub e1 e2
compileExpr (MultW8 e1 e2) = compileMult e1 e2
compileExpr (DivW8 e1 e2) = compileDiv e1 e2
compileExpr (RemW8 e1 e2) = compileMod e1 e2
compileExpr (QuotW8 e1 e2) = compileDiv e1 e2
compileExpr (ModW8 e1 e2) = compileMod e1 e2
compileExpr (AndW8 e1 e2) = compileAnd e1 e2
compileExpr (OrW8 e1 e2) = compileOr e1 e2
compileExpr (XorW8 e1 e2) = compileXor e1 e2
compileExpr (CompW8 e) = compileComp e
compileExpr (ShfLW8 e1 e2) = compileShiftLeft e1 e2
compileExpr (ShfRW8 e1 e2) = compileShiftRight e1 e2
compileExpr (IfW8 e1 e2 e3) = compileIfSubExpr e1 e2 e3
compileExpr (TestBW8 e1 e2) = compileTwoSubExpr "testBW8" e1 e2
compileExpr (SetBW8 e1 e2) = compileTwoSubExpr "setBW8" e1 e2
compileExpr (ClrBW8 e1 e2) = compileTwoSubExpr "clrBW8" e1 e2
compileExpr (LitW16 w) = return $ show w
compileExpr (ShowW16 e) = compileSubExpr "showWord16" e
compileExpr (RefW16 n) = compileRef n
compileExpr (RemArgW16 b) = compileArg b
compileExpr (RemBindW16 b) = compileBind b
compileExpr (FromIntW16 e) = compileFromInt "uint16_t" e
compileExpr (ToIntW16 e) = compileToInt e
compileExpr (NegW16 e) = compileNeg e
compileExpr (SignW16 e) = compileSign e
compileExpr (AddW16 e1 e2) = compileAdd e1 e2
compileExpr (SubW16 e1 e2) = compileSub e1 e2
compileExpr (MultW16 e1 e2) = compileMult e1 e2
compileExpr (DivW16 e1 e2) = compileDiv e1 e2
compileExpr (RemW16 e1 e2) = compileMod e1 e2
compileExpr (QuotW16 e1 e2) = compileDiv e1 e2
compileExpr (ModW16 e1 e2) = compileMod e1 e2
compileExpr (AndW16 e1 e2) = compileAnd e1 e2
compileExpr (OrW16 e1 e2) = compileOr e1 e2
compileExpr (XorW16 e1 e2) = compileXor e1 e2
compileExpr (CompW16 e) = compileComp e
compileExpr (ShfLW16 e1 e2) = compileShiftLeft e1 e2
compileExpr (ShfRW16 e1 e2) = compileShiftRight e1 e2
compileExpr (IfW16 e1 e2 e3) = compileIfSubExpr e1 e2 e3
compileExpr (TestBW16 e1 e2) = compileTwoSubExpr "testBW16" e1 e2
compileExpr (SetBW16 e1 e2) = compileTwoSubExpr "setBW16" e1 e2
compileExpr (ClrBW16 e1 e2) = compileTwoSubExpr "clrBW16" e1 e2
compileExpr (LitW32 w) = return $ show w
compileExpr (ShowW32 e) = compileSubExpr "showWord32" e
compileExpr (RefW32 n) = compileRef n
compileExpr (RemArgW32 b) = compileArg b
compileExpr (RemBindW32 b) = compileBind b
compileExpr (FromIntW32 e) = compileFromInt "uint32_t" e
compileExpr (NegW32 e) = compileNeg e
compileExpr (SignW32 e) = compileSign e
compileExpr (AddW32 e1 e2) = compileAdd e1 e2
compileExpr (SubW32 e1 e2) = compileSub e1 e2
compileExpr (MultW32 e1 e2) = compileMult e1 e2
compileExpr (DivW32 e1 e2) = compileDiv e1 e2
compileExpr (RemW32 e1 e2) = compileMod e1 e2
compileExpr (QuotW32 e1 e2) = compileDiv e1 e2
compileExpr (ModW32 e1 e2) = compileMod e1 e2
compileExpr (AndW32 e1 e2) = compileAnd e1 e2
compileExpr (OrW32 e1 e2) = compileOr e1 e2
compileExpr (XorW32 e1 e2) = compileXor e1 e2
compileExpr (CompW32 e) = compileComp e
compileExpr (ShfLW32 e1 e2) = compileShiftLeft e1 e2
compileExpr (ShfRW32 e1 e2) = compileShiftRight e1 e2
compileExpr (IfW32 e1 e2 e3) = compileIfSubExpr e1 e2 e3
compileExpr (TestBW32 e1 e2) = compileTwoSubExpr "testBW32" e1 e2
compileExpr (SetBW32 e1 e2) = compileTwoSubExpr "setBW32" e1 e2
compileExpr (ClrBW32 e1 e2) = compileTwoSubExpr "clrBW32" e1 e2
compileExpr (LitI8 w) = return $ show w
compileExpr (ShowI8 e) = compileSubExpr "showInt8" e
compileExpr (RefI8 n) = compileRef n
compileExpr (RemArgI8 b) = compileArg b
compileExpr (RemBindI8 b) = compileBind b
compileExpr (FromIntI8 e) = compileFromInt "int8_t" e
compileExpr (ToIntI8 e) = compileToInt e
compileExpr (NegI8 e) = compileNeg e
compileExpr (SignI8 e) = compileSubExpr "sign8" e
compileExpr (AddI8 e1 e2) = compileAdd e1 e2
compileExpr (SubI8 e1 e2) = compileSub e1 e2
compileExpr (MultI8 e1 e2) = compileMult e1 e2
compileExpr (DivI8 e1 e2) = compileTwoSubExpr "div8" e1 e2
compileExpr (RemI8 e1 e2) = compileMod e1 e2
compileExpr (QuotI8 e1 e2) = compileDiv e1 e2
compileExpr (ModI8 e1 e2) = compileTwoSubExpr "mod8" e1 e2
compileExpr (AndI8 e1 e2) = compileAdd e1 e2
compileExpr (OrI8 e1 e2) = compileOr e1 e2
compileExpr (XorI8 e1 e2) = compileXor e1 e2
compileExpr (CompI8 e) = compileComp e
compileExpr (ShfLI8 e1 e2) = compileShiftLeft e1 e2  -- ToDo: need runtinme??
compileExpr (ShfRI8 e1 e2) = compileShiftRight e1 e2
compileExpr (IfI8 e1 e2 e3) = compileIfSubExpr e1 e2 e3
compileExpr (TestBI8 e1 e2) = compileTwoSubExpr "testBI8" e1 e2
compileExpr (SetBI8 e1 e2) = compileTwoSubExpr "setBI8" e1 e2
compileExpr (ClrBI8 e1 e2) = compileTwoSubExpr "clrBI8" e1 e2
compileExpr (LitI16 w) = return $ show w
compileExpr (ShowI16 e) = compileSubExpr "showInt16" e
compileExpr (RefI16 n) = compileRef n
compileExpr (RemArgI16 b) = compileArg b
compileExpr (RemBindI16 b) = compileBind b
compileExpr (FromIntI16 e) = compileFromInt "int16_t" e
compileExpr (ToIntI16 e) = compileToInt e
compileExpr (NegI16 e) = compileNeg e
compileExpr (SignI16 e) = compileSubExpr "sign16" e
compileExpr (AddI16 e1 e2) = compileAdd e1 e2
compileExpr (SubI16 e1 e2) = compileSub e1 e2
compileExpr (MultI16 e1 e2) = compileMult e1 e2
compileExpr (DivI16 e1 e2) = compileTwoSubExpr "div16" e1 e2
compileExpr (RemI16 e1 e2) = compileMod e1 e2
compileExpr (QuotI16 e1 e2) = compileDiv e1 e2
compileExpr (ModI16 e1 e2) = compileTwoSubExpr "mod16" e1 e2
compileExpr (AndI16 e1 e2) = compileAnd e1 e2
compileExpr (OrI16 e1 e2) = compileOr e1 e2
compileExpr (XorI16 e1 e2) = compileXor e1 e2
compileExpr (CompI16 e) = compileComp e
compileExpr (ShfLI16 e1 e2) = compileShiftLeft e1 e2
compileExpr (ShfRI16 e1 e2) = compileShiftRight e1 e2
compileExpr (IfI16 e1 e2 e3) = compileIfSubExpr e1 e2 e3
compileExpr (TestBI16 e1 e2) = compileTwoSubExpr "testBI16" e1 e2
compileExpr (SetBI16 e1 e2) = compileTwoSubExpr "setBI16" e1 e2
compileExpr (ClrBI16 e1 e2) = compileTwoSubExpr "clrBI16" e1 e2
compileExpr (LitI32 w) = return $ show w
compileExpr (ShowI32 e) = compileSubExpr "showInt32" e
compileExpr (RefI32 n) = compileRef n
compileExpr (RemArgI32 b) = compileArg b
compileExpr (RemBindI32 b) = compileBind b
compileExpr (FromIntI32 e) = compileFromInt "int32_t" e
compileExpr (ToIntI32 e) = compileToInt e
compileExpr (NegI32 e) = compileNeg e
compileExpr (SignI32 e) = compileSubExpr "sign32" e
compileExpr (AddI32 e1 e2) = compileAdd e1 e2
compileExpr (SubI32 e1 e2) = compileSub e1 e2
compileExpr (MultI32 e1 e2) = compileMult e1 e2
compileExpr (DivI32 e1 e2) = compileTwoSubExpr "div32" e1 e2
compileExpr (RemI32 e1 e2) = compileMod e1 e2
compileExpr (QuotI32 e1 e2) = compileDiv e1 e2
compileExpr (ModI32 e1 e2) = compileTwoSubExpr "mod32" e1 e2
compileExpr (AndI32 e1 e2) = compileAnd e1 e2
compileExpr (OrI32 e1 e2) = compileOr e1 e2
compileExpr (XorI32 e1 e2) = compileXor e1 e2
compileExpr (CompI32 e) = compileComp e
compileExpr (ShfLI32 e1 e2) = compileShiftLeft e1 e2
compileExpr (ShfRI32 e1 e2) = compileShiftRight e1 e2
compileExpr (IfI32 e1 e2 e3) = compileIfSubExpr e1 e2 e3
compileExpr (TestBI32 e1 e2) = compileTwoSubExpr "testBI32" e1 e2
compileExpr (SetBI32 e1 e2) = compileTwoSubExpr "setBI32" e1 e2
compileExpr (ClrBI32 e1 e2) = compileTwoSubExpr "clrBI32" e1 e2
compileExpr (LitI w) = return $ show w
compileExpr (ShowI e) = compileSubExpr "showInt32" e
compileExpr (RefI n) = compileRef n
compileExpr (RemArgI b) = compileArg b
compileExpr (RemBindI b) = compileBind b
compileExpr (NegI e) = compileNeg e
compileExpr (SignI e) = compileSubExpr "sign32" e
compileExpr (AddI e1 e2) = compileAdd e1 e2
compileExpr (SubI e1 e2) = compileSub e1 e2
compileExpr (MultI e1 e2) = compileMult e1 e2
compileExpr (DivI e1 e2) = compileTwoSubExpr "div32" e1 e2
compileExpr (RemI e1 e2) = compileMod e1 e2
compileExpr (QuotI e1 e2) = compileDiv e1 e2
compileExpr (ModI e1 e2) = compileTwoSubExpr "mod32" e1 e2
compileExpr (AndI e1 e2) = compileAnd e1 e2
compileExpr (OrI e1 e2) = compileOr e1 e2
compileExpr (XorI e1 e2) = compileXor e1 e2
compileExpr (CompI e) = compileComp e
compileExpr (ShfLI e1 e2) = compileShiftLeft e1 e2
compileExpr (ShfRI e1 e2) = compileShiftRight e1 e2
compileExpr (IfI e1 e2 e3) = compileIfSubExpr e1 e2 e3
compileExpr (TestBI e1 e2) = compileTwoSubExpr "testBI32" e1 e2
compileExpr (SetBI e1 e2) = compileTwoSubExpr "setBI32" e1 e2
compileExpr (ClrBI e1 e2) = compileTwoSubExpr "clrBI32" e1 e2
compileExpr (LitList8 ws) = return $ "(uint8_t * ) (const byte[]) {255, " ++ (show $ length ws) ++ compListLit ws
  where
    compListLit :: [Word8] -> String
    compListLit [] = "}"
    compListLit (w : ws') = "," ++ show w ++ compListLit ws'
compileExpr (RefList8 n) = compileRef n
compileExpr (RemBindList8 b) = compileBind b
compileExpr (IfL8 e1 e2 e3) = compileIfSubExpr e1 e2 e3
compileExpr (ElemList8 e1 e2) = compileTwoSubExpr "list8Elem" e1 e2
compileExpr (LenList8 e) = compileSubExpr "list8Len" e
compileExpr (ConsList8 e1 e2) = compileTwoSubExpr "list8Cons" e1 e2
compileExpr (ApndList8 e1 e2) = compileTwoSubExpr "list8Apnd" e1 e2
compileExpr (SliceList8 e1 e2 e3) = compileThreeSubExpr "list8Slice" e1 e2 e3
-- ToDo:
-- compileExpr (PackList8 es) = [exprLCmdVal EXPRL_PACK, fromIntegral $ length es] ++ (foldl (++) [] (map compileExpr es))
compileExpr (LitFloat f) = return $ show f -- ToDo:  Is this correct?
compileExpr (ShowFloat e1 e2) = compileTwoSubExpr "showF" e1 e2
compileExpr (RefFloat n) = compileRef n
compileExpr (RemArgFloat b) = compileArg b
compileExpr (RemBindFloat b) = compileBind b
compileExpr (FromIntFloat e) = compileFromInt "float" e
compileExpr (NegFloat e) = compileNeg e
compileExpr (SignFloat e) = compileSubExpr "signF" e
compileExpr (AddFloat e1 e2) = compileAdd e1 e2
compileExpr (SubFloat e1 e2) = compileSub e1 e2
compileExpr (MultFloat e1 e2) = compileMult e1 e2
compileExpr (DivFloat e1 e2) = compileDiv e1 e2
compileExpr (IfFloat e1 e2 e3) = compileIfSubExpr e1 e2 e3
compileExpr (TruncFloat e) = compileSubExpr "trunc" e
compileExpr (FracFloat e) = compileSubExpr "frac" e
compileExpr (RoundFloat e) = compileSubExpr "round" e
compileExpr (CeilFloat e) = compileSubExpr "ceil" e
compileExpr (FloorFloat e) = compileSubExpr "floor" e
compileExpr PiFloat = return "M_PI"
compileExpr (ExpFloat e) = compileSubExpr "exp" e
compileExpr (LogFloat e) = compileSubExpr "log" e
compileExpr (SqrtFloat e) = compileSubExpr "sqrt" e
compileExpr (SinFloat e) = compileSubExpr "sin" e
compileExpr (CosFloat e) = compileSubExpr "cos" e
compileExpr (TanFloat e) = compileSubExpr "tan" e
compileExpr (AsinFloat e) = compileSubExpr "asin" e
compileExpr (AcosFloat e) = compileSubExpr "acos" e
compileExpr (AtanFloat e) = compileSubExpr "atan" e
compileExpr (Atan2Float e1 e2) = compileTwoSubExpr "atan2" e1 e2
compileExpr (SinhFloat e) = compileSubExpr "sinh" e
compileExpr (CoshFloat e) = compileSubExpr "cosh" e
compileExpr (TanhFloat e) = compileSubExpr "tanh" e
compileExpr (PowerFloat e1 e2) = compileTwoSubExpr "pow" e1 e2
compileExpr (IsNaNFloat e) = compileSubExpr "isnan" e
compileExpr (IsInfFloat e) = compileSubExpr "isinf" e
compileExpr (AppFUnit n m) = compileAppExpr n UnitType RemBindUnit m
compileExpr (AppFW8 n m) = compileAppExpr n Word8Type RemBindW8 m
compileExpr _              = error "compileExpr: Unsupported expression"

compileAppExpr :: ExprB a => String -> CompileType -> (Int -> Expr a) -> Expr a -> State CompileState String
compileAppExpr n t rb m = do
    (body, args) <- compileArgsE m
    s' <- get
    let newFunc = (MkCompilableExpr body, t, n)
    if not $ funcExprElemToDo n (funcExprsToDo s')
    then put s' {funcExprsToDo = newFunc : funcExprsToDo s'}
    else return ()
    return $ n ++ "(" ++ args ++ ")"

funcExprElemToDo :: String -> [(CompilableExpr, CompileType, String)] -> Bool
funcExprElemToDo _ [] = False
funcExprElemToDo s (f:fs) = case f of
    (_, _, s') -> if s == s' then True else funcExprElemToDo s fs

compileArgsE :: Expr a -> State CompileState (Expr a, String)
compileArgsE (AppW8Unit f e) = do
    (func, string) <- compileArgsE f
    ce <- compileExpr e
    return (func, ce ++ if null string then "" else ", " ++ string)
compileArgsE (AppW8W8 f e) = do
    (func, string) <- compileArgsE f
    ce <- compileExpr e
    return (func, ce ++ if null string then "" else "," ++ string)
compileArgsE f' = return (f', "")
