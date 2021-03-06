{-# LANGUAGE TupleSections #-}

-- | Handles Eth-style gas computations, used by the standard gas model.
module Masala.VM.Gas
    (
     handleGas
    ,refund
    ,refundSuicide
    ,deductGas
    ) where

import Masala.Word
import Masala.VM.Types
import Masala.VM.Memory
import Masala.Instruction
import qualified Data.Map as M
import Prelude hiding (EQ,LT,GT)
import Data.Maybe
import Control.Lens
import Control.Monad.Except

-- | specify a stateful gas calculation
data GasCalc =
    MemSize U256 |
    StoreOp { _gcStoreLoc :: U256, _gcStoreValue :: U256 } |
    GasCall { _gcCallMemSize :: U256, _gcCallAddy :: (Maybe Address) }
    deriving (Eq,Show)


-- | Compute gas for instruction and deduct, throwing error if out of gas.
-- | This is also where different gas models are handled.
handleGas :: MonadExt m => GasModel -> Instruction -> Maybe ParamSpec -> [U256] -> VM m ()
handleGas (FixedGasModel g) _ _ _ = deductGas g
handleGas _ i ps svs = do
  let (callg,a) = computeGas i (ps,svs)
  calcg <-
      case a of
        Nothing -> return 0
        (Just c) ->
            case c of
              (MemSize sz) -> computeMemGas sz
              (StoreOp loc off) -> computeStoreGas loc off
              (GasCall sz addr) -> (+) <$> computeMemGas sz
                                       <*> computeCallGas addr
  deductGas (calcg + callg)


-- | deduct, throwing error if out of gas
deductGas :: MonadExt m => Gas -> VM m ()
deductGas total = do
    pg <- use gas
    let gas' = pg - total
    if gas' < 0
    then do
      gas .= 0
      throwError $ "Out of gas, previous gas=" ++ show pg ++
                 ", required=" ++ show total ++
                 ", balance= " ++ show gas'
    else do
      extDebug $ "gas used: " ++ show total
      gas .= gas'


computeMemGas :: Monad m => U256 -> VM m Gas
computeMemGas newSzBytes = do
  let toWordSize v = (v + 31) `div` 32
      newSzWords = fromIntegral $ toWordSize newSzBytes
      fee s = ((s * s) `div` 512) + (s * gas_memory)
  oldSzWords <- fromIntegral <$> msize
  return $ if newSzWords > oldSzWords
           then fee newSzWords - fee oldSzWords
           else 0

computeStoreGas :: MonadExt m => U256 -> U256 -> VM m Gas
computeStoreGas l v' = do
  v <- sload l
  if v == 0 && v' /= 0
  then return gas_sset
  else if v /= 0 && v' == 0
       then refund gas_sclear >> return gas_sreset
       else return gas_sreset


computeCallGas :: MonadExt m => Maybe Address -> VM m Gas
computeCallGas Nothing = return 0
computeCallGas (Just a) = do
  isNew <- extIsCreate a
  return $ if isNew then gas_callnewaccount else 0



-- | refund to running account
refund :: MonadExt m => Gas -> VM m ()
refund g = do
  a <- view address
  extRefund a g

-- | refund on suicide
refundSuicide :: MonadExt m => VM m ()
refundSuicide = refund gas_suicide

computeGas :: Instruction -> (Maybe ParamSpec,[U256]) -> (Gas,Maybe GasCalc)
computeGas i p = (\(g,c) -> (g + fgas,c)) $ iGas i p
                 where fgas = fromMaybe 0 $ M.lookup i fixedGas

memSize :: U256 -> U256 -> Maybe GasCalc
memSize a b = Just $ MemSize (a + b)

wordSize :: U256 -> Integer
wordSize = fromIntegral . length . u256ToU8s

callGas :: Instruction -> [U256] -> (Gas,Maybe GasCalc)
callGas i [g,t,gl,io,il,oo,ol] = (fromIntegral g + (if gl > 0 then gas_callvalue else 0),
                                  Just (GasCall (io + il + oo + ol)
                                                (if i == CALL then Just (toAddress t) else Nothing)))
callGas _ _ = (0,Nothing) -- errors caught in dispatch catch-all

-- | dispatch to specify/compute gas
iGas :: Instruction -> (Maybe ParamSpec,[U256]) -> (Gas,Maybe GasCalc)
iGas _ (Just (Log n),[a,b]) = (gas_log + (fromIntegral n * gas_logtopic) + (fromIntegral b * gas_logdata),
                       memSize a b)
iGas EXP (_,[_a,b]) = (gas_exp + (wordSize b * gas_expbyte), Nothing)
iGas SSTORE (_,[a,b]) = (0,Just $ StoreOp a b)
iGas SUICIDE _ = (0,Nothing) -- refund will happen in execution
iGas MLOAD (_,[a]) = (0,memSize a 32)
iGas MSTORE (_,[a,_]) = (0,memSize a 32)
iGas MSTORE8 (_,[a,_]) = (0,memSize a 1)
iGas RETURN (_,[a,b]) = (0,memSize a b)
iGas SHA3 (_,[a,b]) = (wordSize b * gas_sha3word,memSize a b)
iGas CALLDATACOPY (_,[a,_b,c]) = (wordSize c * gas_copy,memSize a c)
iGas CODECOPY (_,[a,_b,c]) = (wordSize c * gas_copy,memSize a c)
iGas EXTCODECOPY (_,[_a,b,_c,d]) = (wordSize d * gas_copy,memSize b d)
iGas CREATE (_,[_a,b,c]) = (0,memSize b c)
iGas CALL (_,s) = callGas CALL s
iGas CALLCODE (_,s) = callGas CALLCODE s
iGas _ _ = (0,Nothing) -- errors caught in dispatch catch-all

--
-- FIXED GAS COSTS, from yellow paper
-- TODO these differ from the go code ...
--

gasZero :: [Instruction]
gasZero = [STOP
          , SUICIDE
          , RETURN]

gasBase :: [Instruction]
gasBase = [ADDRESS
          , ORIGIN
          , CALLER
          , CALLVALUE
          , CALLDATASIZE
          , CODESIZE
          , GASPRICE
          , COINBASE
          , TIMESTAMP
          , NUMBER
          , DIFFICULTY
          , GASLIMIT
          , POP
          , PC
          , MSIZE
          , GAS]

gasVeryLow :: [Instruction]
gasVeryLow = [ADD
             , SUB
             , NOT
             , LT
             , GT
             , SLT
             , SGT
             , EQ
             , ISZERO
             , AND
             , OR
             , XOR
             , BYTE
             , CALLDATALOAD
             , MLOAD
             , MSTORE
             , MSTORE8]
             ++ [PUSH1 .. PUSH32]
             ++ [DUP1 .. DUP16]
             ++ [SWAP1 .. SWAP16]

gasLow :: [Instruction]
gasLow = [MUL
         , DIV
         , SDIV
         , MOD
         , SMOD
         , SIGNEXTEND]

gasMid :: [Instruction]
gasMid = [ADDMOD
         , MULMOD
         , JUMP]

gasHigh :: [Instruction]
gasHigh = [JUMPI]

gasExt :: [Instruction]
gasExt = [BALANCE
         , EXTCODESIZE
         , BLOCKHASH]

-- | Lookup for fixed gas costs.
fixedGas :: M.Map Instruction Gas
fixedGas = M.fromList $
          map (,gas_zero) gasZero ++
          map (,gas_base) gasBase ++
          map (,gas_verylow) gasVeryLow ++
          map (,gas_low) gasLow ++
          map (,gas_mid) gasMid ++
          map (,gas_high) gasHigh ++
          map (,gas_ext) gasExt ++
              [(SLOAD, gas_sload)
              ,(SHA3, gas_sha3)
              ,(CREATE,gas_create)
              ,(CALL,gas_call)
              ,(CALLCODE,gas_call)
              ,(JUMPDEST,gas_jumpdest)]

--
-- GAS CONSTANTS from yellow paper
--

gas_zero :: Gas; gas_zero = 0
gas_base :: Gas; gas_base = 2
gas_verylow :: Gas; gas_verylow = 3
gas_low :: Gas; gas_low = 5
gas_mid :: Gas; gas_mid = 8
gas_high :: Gas; gas_high = 10
gas_ext :: Gas; gas_ext = 20
gas_sload :: Gas; gas_sload = 50
gas_jumpdest :: Gas; gas_jumpdest = 1
gas_sset :: Gas; gas_sset = 20000
gas_sreset :: Gas; gas_sreset = 5000
gas_sclear :: Gas; gas_sclear = 15000
gas_suicide :: Gas; gas_suicide = 24000
gas_create :: Gas; gas_create = 32000
-- gas_codedeposit :: Gas; gas_codedeposit = 200
gas_call :: Gas; gas_call = 40
gas_callvalue :: Gas; gas_callvalue = 9000
-- gas_callstipend :: Gas; gas_callstipend = 2300
gas_callnewaccount :: Gas; gas_callnewaccount = 25000
gas_exp :: Gas; gas_exp = 10
gas_expbyte :: Gas; gas_expbyte = 10
gas_memory :: Gas; gas_memory = 3
-- gas_txdatazero :: Gas; gas_txdatazero = 4
-- gas_txdatanonzero :: Gas; gas_txdatanonzero = 68
-- gas_transaction :: Gas; gas_transaction = 21000
gas_log :: Gas; gas_log = 375
gas_logdata :: Gas; gas_logdata = 8
gas_logtopic :: Gas; gas_logtopic = 375
gas_sha3 :: Gas; gas_sha3 = 30
gas_sha3word :: Gas; gas_sha3word = 6
gas_copy :: Gas; gas_copy = 3
