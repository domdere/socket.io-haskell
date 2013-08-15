{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module SocketIO.Server where

import SocketIO.Util
import SocketIO.Type
import SocketIO.Parser
import SocketIO.Session

import Network.Wai
import Network.Wai.Handler.Warp     (run)
import Network.HTTP.Types           (status200)


import Control.Applicative           ((<$>), (<*>))            
import Control.Concurrent           (threadDelay)            
import Control.Concurrent.MVar   
import Control.Monad                ((>=>))
import Control.Monad.Trans          (liftIO)
import Control.Monad.Trans.Resource (ResourceT, runResourceT)
import Control.Monad.Reader       


import qualified Data.ByteString.Lazy.Char8 as BL
import qualified Data.Text.Lazy as TL
import qualified Data.Text as T
import Data.Conduit.List (consume)
import Data.Conduit (($$))
import Data.Monoid (mconcat)



processRequest :: Request -> IO SocketRequest
processRequest request = do
    b <- parseBody request
    return $ case path of
        [n, p]          -> SocketRequest method b (n,  p,  "", "")
        [n, p, t]       -> SocketRequest method b (n,  p,  t,  "")
        [n, p, t, s]    -> SocketRequest method b (n,  p,  t,  s)
        _               -> SocketRequest method b ("", "", "", "")
    where   method  = requestMethod request
            path    = map TL.fromStrict . cleanup . pathInfo $ request
            cleanup = filter (/= "")

processSocketRequest :: SocketRequest -> IO Connection
processSocketRequest (SocketRequest _ _ ("", "", "", "")) = return Disconnection  
processSocketRequest (SocketRequest "GET" _ (n, p, "", "")) = return Handshake  
processSocketRequest (SocketRequest "GET" _ (n, p, t, s)) = return (Connection s)  
processSocketRequest (SocketRequest "POST" b (n, p, t, s)) = return (Packet s b)  
processSocketRequest (SocketRequest _ _ _) = return Disconnection  

preprocess :: Request -> IO Connection
preprocess = processRequest >=> processSocketRequest


server :: Connection -> SessionM Response 
server Handshake = do
    sessionID <- createSession
    return $ text (sessionID <> ":60:60:xhr-polling")
server (Connection sessionID) = do
    status <- lookupSession sessionID
    case status of
        Connecting -> do
            updateSession sessionID Connected
            return (text "1::")
        Connected -> do
            return (text "8::")
        _ -> do
            return (text "7:::Disconnected")
server (Packet sessionID body) = do
    liftIO $ print message
    case message of
        _ -> do
            deleteSession sessionID
            return (text $ fromString $ show body)
    where   message = parseMessage body
server _ = return $ text "1::"

runSession :: Local -> Env -> SessionM a -> IO a
runSession local env m = runReaderT (runReaderT (runSessionM m) env) local

parseBody :: Request -> IO BL.ByteString
parseBody req = fromByteString . mconcat <$> runResourceT (requestBody req $$ consume)

text = responseLBS status200 header . fromText

main = do
    table <- newTable
    toilet <- newEmptyMVar
    run 4000 $ liftIO . preprocess >=> liftIO . runSession (Local toilet) (Env table) . server

header = [
    ("Content-Type", "text/plain"),
    ("Connection", "keep-alive"),
    ("Access-Control-Allow-Credentials", "true"),
    ("Access-Control-Allow-Origin", "http://localhost:3000") 
    ]