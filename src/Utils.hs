{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE NoImplicitPrelude   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell     #-}
{-# LANGUAGE TypeApplications    #-}
{-# LANGUAGE TypeFamilies        #-}
{-# LANGUAGE TypeOperators       #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE DeriveAnyClass      #-}
{-# LANGUAGE DeriveGeneric       #-}
{-# LANGUAGE DerivingStrategies  #-}
{-# LANGUAGE NumericUnderscores  #-}

module Utils where


import           Types
import           Control.Monad          hiding (fmap)
import           Data.Text              (Text,pack)
import           Plutus.Contract
import qualified PlutusTx
import qualified PlutusTx.AssocMap      as Map
import           PlutusTx.Prelude       hiding (Semigroup(..), unless)
import           Ledger                 hiding (singleton)
import qualified Plutus.V1.Ledger.Ada   as Ada
import           Text.Printf            (printf)
import           Wallet.Emulator.Wallet
import           Data.Monoid            (Last (..))
import           Plutus.Trace.Emulator  as Emulator


-- GLOBAL CONST

{-# INLINABLE oracle_ppkh #-}
oracle_ppkh :: PaymentPubKeyHash
oracle_ppkh = (mockWalletPaymentPubKeyHash $ knownWallet 5) 

{-# INLINABLE oracle_pkh #-}
oracle_pkh :: PubKeyHash 
oracle_pkh = "bf342ddd3b1a6191d4ce936c92d29834d6879edf2849eaea84c827f8"

{-# INLINABLE service_percfee #-}
service_percfee :: Integer
service_percfee = 5

{-# INLINABLE service_minfee #-}
service_minfee :: Integer
service_minfee = 2_000_000

{-# INLINABLE bet_minamount #-}
bet_minamount :: Integer
bet_minamount = 5_000_000




-- ON CHAIN HELPER FUNCTIONS

{-# INLINABLE getFeeCalculation #-}
getFeeCalculation :: Integer -> Integer
getFeeCalculation amount = max percent service_minfee
    where 
        percent = PlutusTx.Prelude.divide (amount* service_percfee) 100



------ TX INPUTS

-- Check the Datum & The Address of the input

{-# INLINABLE isScriptInputValid #-}
isScriptInputValid :: TxInfo -> BetDatum -> Bool 
isScriptInputValid info betdatum = 
    case (txOutDatumHash . txInInfoResolved) input of
        Nothing -> False
        Just dh -> case findDatum dh info of
            Nothing -> False
            Just (Datum d) -> case (PlutusTx.fromBuiltinData d)::(Maybe BetDatum) of
                Nothing -> traceError "Error: Cannot decode Datum"
                Just x -> (x == betdatum)
    where
        input = getScriptInput $ txInfoInputs info    


{-# INLINABLE isFromScript #-}
isFromScript :: TxOut -> Bool
isFromScript i = 
    case txOutDatumHash i of
        Nothing -> False
        Just _  -> True


{-# INLINABLE getScriptInput #-}
getScriptInput :: [TxInInfo] -> TxInInfo
getScriptInput i = 
    case [x | x <- i, isFromScript $ txInInfoResolved x] of
        [y] -> y
        _ -> traceError "Error: Expected 1 script input"


{-# INLINABLE getScriptInputValue #-}
getScriptInputValue :: [TxInInfo] -> Integer
getScriptInputValue i = Ada.getLovelace $ Ada.fromValue $ txOutValue $ txInInfoResolved $ getScriptInput i


{-# INLINABLE getInputValue #-}
getInputValue :: [TxInInfo] -> Integer
getInputValue i =  sum input_list
    where 
        input_list = map (Ada.getLovelace . Ada.fromValue . txOutValue . txInInfoResolved) i --(filter (not . isFromScript . txInInfoResolved) i)  

{-# INLINABLE getTxValueAt #-}
getTxValueAt :: PaymentPubKeyHash -> [TxOut] -> Integer
getTxValueAt pkh list = sum $ map (Ada.getLovelace . Ada.fromValue . txOutValue) txs
    where 
        txs = filter (\x -> txOutAddress x == pubKeyHashAddress pkh Nothing) list

{-# INLINABLE getScriptOutput #-}
getScriptOutput :: [TxOut] -> TxOut
getScriptOutput i = 
    case [x | x <- i, isFromScript x] of
        [y] -> y
        _ -> traceError "Error: Expected 1 script ouput"

{-# INLINABLE getScriptOutputDatum #-}
getScriptOutputDatum :: TxInfo -> BetDatum
getScriptOutputDatum info =
    case output_datumhash of
        Nothing -> traceError "Error: Output Datum Hash not found"
        Just dh -> 
            case Map.lookup dh map_datum of
                Nothing -> traceError "Error: Output Datum not found"
                Just (Datum d) -> 
                    case (PlutusTx.fromBuiltinData d)::(Maybe BetDatum) of
                        Nothing -> traceError "Error: Cannot decode Output Datum"
                        Just x -> x
    where
        map_datum = Map.fromList (txInfoData info)
        output_datumhash = txOutDatumHash $ getScriptOutput $ txInfoOutputs info


-- OFF CHAIN HELPER FUNCTIONS  --

redeemerMatchingUtxo :: BetRedeemer -> ChainIndexTxOut -> Bool
redeemerMatchingUtxo r o = case _ciTxOutDatum o of
    Left _          -> False
    Right (Datum d) -> case PlutusTx.fromBuiltinData d of
        Nothing -> False
        Just d2 -> case r of
                    (BetRedeemerAccept _ _) -> (r_matchID r == (d_matchID d2)) &&
                                               (r_creator r == (d_creator d2)) &&
                                               ((d_status d2) == AwaitingBet)
                    (BetRedeemerOracle _ _) -> (r_matchID r == (d_matchID d2)) &&
                                               ((d_status d2) == AwaitingResult)
                    (BetRedeemerClose _) ->    (r_matchID r == (d_matchID d2))              


--- UNUSED
acceptSlotMatchingUtxo :: POSIXTime -> ChainIndexTxOut -> Bool
acceptSlotMatchingUtxo s o = case _ciTxOutDatum o of
    Left _          -> False
    Right (Datum d) -> case PlutusTx.fromBuiltinData d of
        Nothing -> False
        Just d2 -> s >= (d_closedAt d2)

--- UNUSED
resultSlotMatchingUtxo :: POSIXTime -> ChainIndexTxOut -> Bool
resultSlotMatchingUtxo s o = case _ciTxOutDatum o of
    Left _          -> False
    Right (Datum d) -> case PlutusTx.fromBuiltinData d of
        Nothing -> False
        Just d2 -> s >= (d_resultlimAt d2)

getTxIdWriter :: CardanoTx -> Maybe TxId
getTxIdWriter x = case PlutusTx.Prelude.filter (\x -> isFromScript $ fst x) (getCardanoTxOutRefs x) of
            [(x,y)] -> Just (txOutRefId $ y)
            _ -> Nothing

getTxDatum :: ChainIndexTxOut -> Contract w s Text BetDatum
getTxDatum o = case _ciTxOutDatum o of
    Left _ -> Plutus.Contract.throwError $ pack $ printf "No Datum found"
    Right (Datum d) -> case PlutusTx.fromBuiltinData d of
        Nothing -> Plutus.Contract.throwError $ pack $ printf "Error Decoding Datum"
        Just d2 -> return d2

getResultTx ::  MatchBet -> ChainIndexTxOut -> Contract w s Text (PaymentPubKeyHash, Integer)
getResultTx mr o = do
    datum <- getTxDatum o
    let amount = PlutusTx.Prelude.divide ((d_amount datum) * (d_odds datum)) 100
    case mr of
        Unknown -> Plutus.Contract.throwError $ pack $ printf "No match result provided"
        _ -> if d_creatorbet datum == mr
            then return (d_creator datum, amount)
            else return (d_acceptor datum, amount)

getFeeTx :: ChainIndexTxOut -> Contract w s Text Integer
getFeeTx o = do
    datum <- getTxDatum o
    let fees = d_fee datum
    return fees
