{-# language PolyKinds, DataKinds, GADTs,
             MultiParamTypeClasses,
             FlexibleInstances, FlexibleContexts,
             ScopedTypeVariables, TypeApplications,
             TypeOperators, DeriveFunctor,
             AllowAmbiguousTypes,
             TupleSections #-}
module Mu.Client.GRpc (
  GrpcClient
, GrpcClientConfig
, grpcClientConfigSimple
, setupGrpcClient'
, gRpcCall
, CompressMode(..)
, GRpcReply(..)
) where

import Control.Monad.IO.Class
import Control.Concurrent.Async
import Control.Concurrent.STM (atomically)
import Control.Concurrent.STM.TMChan
import Control.Concurrent.STM.TMVar
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as BS
import Data.Conduit
import qualified Data.Conduit.Combinators as C
import Data.Conduit.TMChan
import GHC.TypeLits
import Network.HTTP2 (ErrorCode)
import Network.HTTP2.Client (ClientIO, TooMuchConcurrency, ClientError, runExceptT)
import Network.GRPC.Proto3Wire.Client (RPC(..), RawReply, CompressMode(..), StreamDone(..),
                                       IncomingEvent(..),OutgoingEvent(..))
import Network.GRPC.Proto3Wire.Client.Helpers

import Mu.Rpc
import Mu.Schema
import Mu.Schema.Adapter.ProtoBuf

setupGrpcClient' :: GrpcClientConfig -> IO (Either ClientError GrpcClient)
setupGrpcClient' = runExceptT . setupGrpcClient

-- | Call a method from a `mu-rpc` definition.
--   This method is thought to be used with `TypeApplications`:
--   > gRpcCall @"packageName" @ServiceDeclaration @"method" 
gRpcCall :: forall (pkg :: Symbol) (s :: Service snm mnm) (methodName :: mnm) h.
            (KnownName pkg, GRpcServiceMethodCall s (s :-->: methodName) h)
         => GrpcClient -> h
gRpcCall = gRpcServiceMethodCall pkgName (Proxy @s) (Proxy @(s :-->: methodName))
  where pkgName = BS.pack (nameVal (Proxy @pkg))

class GRpcServiceMethodCall (s :: Service snm mnm) (m :: Method mnm) h where
  gRpcServiceMethodCall :: ByteString -> Proxy s -> Proxy m -> GrpcClient -> h
instance (KnownName serviceName, GRpcMethodCall m h)
         => GRpcServiceMethodCall ('Service serviceName methods) m h where
  gRpcServiceMethodCall pkgName _ = gRpcMethodCall pkgName svrName
    where svrName = BS.pack (nameVal (Proxy @serviceName))

data GRpcReply a
  = GRpcTooMuchConcurrency TooMuchConcurrency
  | GRpcErrorCode ErrorCode
  | GRpcErrorString String
  | GRpcClientError ClientError
  | GRpcOk a
  deriving (Show, Functor)

buildGRpcReply1 :: Either TooMuchConcurrency (RawReply a) -> GRpcReply a
buildGRpcReply1 (Left tmc) = GRpcTooMuchConcurrency tmc
buildGRpcReply1 (Right (Left ec)) = GRpcErrorCode ec
buildGRpcReply1 (Right (Right (_, _, Left es))) = GRpcErrorString es
buildGRpcReply1 (Right (Right (_, _, Right r))) = GRpcOk r

buildGRpcReply2 :: Either TooMuchConcurrency (r, (RawReply a)) -> GRpcReply a
buildGRpcReply2 (Left tmc) = GRpcTooMuchConcurrency tmc
buildGRpcReply2 (Right (_, (Left ec))) = GRpcErrorCode ec
buildGRpcReply2 (Right (_, (Right (_, _, Left es)))) = GRpcErrorString es
buildGRpcReply2 (Right (_, (Right (_, _, Right r)))) = GRpcOk r

buildGRpcReply3 :: Either TooMuchConcurrency v -> GRpcReply ()
buildGRpcReply3 (Left tmc) = GRpcTooMuchConcurrency tmc
buildGRpcReply3 (Right _)  = GRpcOk ()

simplifyResponse :: ClientIO (GRpcReply a) -> IO (GRpcReply a)
simplifyResponse reply = do
  r <- runExceptT reply
  case r of
    Left e  -> return $ GRpcClientError e
    Right v -> return v

class GRpcMethodCall method h where
  gRpcMethodCall :: ByteString -> ByteString -> Proxy method -> GrpcClient -> h

instance (KnownName name, HasProtoSchema vsch vty v, HasProtoSchema rsch rty r)
         => GRpcMethodCall ('Method name '[ 'ArgSingle vsch vty ] ('RetSingle rsch rty))
                           (v -> IO (GRpcReply r)) where
  gRpcMethodCall pkgName srvName _ client x
    = simplifyResponse $ 
      buildGRpcReply1 <$>
      rawUnary (toProtoViaSchema @vsch, fromProtoViaSchema @rsch) rpc client x
    where methodName = BS.pack (nameVal (Proxy @name))
          rpc = RPC pkgName srvName methodName

instance (KnownName name, HasProtoSchema vsch vty v, HasProtoSchema rsch rty r)
         => GRpcMethodCall ('Method name '[ 'ArgStream vsch vty ] ('RetSingle rsch rty))
                           (CompressMode -> IO (ConduitT v Void IO (GRpcReply r))) where
  gRpcMethodCall pkgName srvName _ client compress
    = do -- Create a new TMChan
         chan <- newTMChanIO :: IO (TMChan v)
         -- Start executing the client in another thread
         promise <- async $ 
            simplifyResponse $ 
            buildGRpcReply2 <$>
            rawStreamClient (toProtoViaSchema @vsch, fromProtoViaSchema @rsch) rpc client ()
                            (\_ -> do nextVal <- liftIO $ atomically $ readTMChan chan
                                      case nextVal of
                                        Nothing -> return ((), Left StreamDone)
                                        Just v  -> return ((), Right (compress, v)))
         -- This conduit feeds information to the other thread
         let go = do x <- await
                     case x of
                       Just v  -> do liftIO $ atomically $ writeTMChan chan v
                                     go
                       Nothing -> do liftIO $ atomically $ closeTMChan chan
                                     liftIO $ wait promise
         return go 
      where methodName = BS.pack (nameVal (Proxy @name))
            rpc = RPC pkgName srvName methodName

instance (KnownName name, HasProtoSchema vsch vty v, HasProtoSchema rsch rty r)
         => GRpcMethodCall ('Method name '[ 'ArgSingle vsch vty ] ('RetStream rsch rty))
                           (v -> IO (ConduitT () (GRpcReply r) IO ())) where
  gRpcMethodCall pkgName srvName _ client x
    = do -- Create a new TMChan
         chan <- newTMChanIO
         var  <- newEmptyTMVarIO  -- if full, this means an error
         -- Start executing the client in another thread
         _ <- async $ do
            v <- simplifyResponse $ 
                 buildGRpcReply3 <$>
                 rawStreamServer (toProtoViaSchema @vsch, fromProtoViaSchema @rsch) rpc client () x
                                 (\_ _ newVal -> liftIO $ atomically $ writeTMChan chan newVal)
            case v of
              GRpcOk () -> liftIO $ atomically $ closeTMChan chan
              _ -> liftIO $ atomically $ putTMVar var v
         -- This conduit feeds information to the other thread
         let go = do err <- liftIO $ atomically $ tryTakeTMVar var
                     case err of
                       Just e  -> yield $ (\_ -> error "this should never happen") <$> e
                       Nothing -> -- no error, everything is fine
                         sourceTMChan chan .| C.map GRpcOk
         return go
      where methodName = BS.pack (nameVal (Proxy @name))
            rpc = RPC pkgName srvName methodName

instance (KnownName name, HasProtoSchema vsch vty v, HasProtoSchema rsch rty r)
         => GRpcMethodCall ('Method name '[ 'ArgStream vsch vty ] ('RetStream rsch rty))
                           (CompressMode -> IO (ConduitT v (GRpcReply r) IO ())) where
  gRpcMethodCall pkgName srvName _ client compress
    = do -- Create a new TMChan
         inchan <- newTMChanIO
         outchan <- newTMChanIO
         var <- newEmptyTMVarIO  -- if full, this means an error
         -- Start executing the client in another thread
         _ <- async $ do
            v <- simplifyResponse $ 
                 buildGRpcReply3 <$>
                 rawGeneralStream
                   (toProtoViaSchema @vsch, fromProtoViaSchema @rsch) rpc client
                   () (\_ ievent -> case ievent of
                                      RecvMessage o -> liftIO $ atomically $ writeTMChan inchan (GRpcOk o)
                                      Invalid e -> liftIO $ atomically $ writeTMChan inchan (GRpcErrorString (show e))
                                      _ -> return () )
                   () (\_ -> do nextVal <- liftIO $ atomically $ readTMChan outchan
                                case nextVal of
                                  Nothing -> return ((), Finalize)
                                  Just v  -> return ((), SendMessage compress v))
            case v of
              GRpcOk () -> liftIO $ atomically $ closeTMChan inchan
              _ -> liftIO $ atomically $ putTMVar var v
         -- This conduit feeds information to the other thread
         let go = do err <- liftIO $ atomically $ tryTakeTMVar var
                     case err of
                       Just e  -> yield $ (\_ -> error "this should never happen") <$> e
                       Nothing -> -- no error, everything is fine
                         do nextOut <- await
                            case nextOut of
                              Just v  -> do liftIO $ atomically $ writeTMChan outchan v
                                            go
                              Nothing -> do r <- liftIO $ atomically $ tryReadTMChan inchan
                                            case r of
                                              Nothing -> return () -- both are empty, end
                                              Just Nothing -> go
                                              Just (Just nextIn) -> yield nextIn >> go
         return go
      where methodName = BS.pack (nameVal (Proxy @name))
            rpc = RPC pkgName srvName methodName