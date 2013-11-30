{-# LANGUAGE OverloadedStrings #-}
module Web.SocketIO.Type.SocketIO where

import Web.SocketIO.Type.String

data Transport = WebSocket | XHRPolling | NoTransport deriving Show

data Configuration = Configuration
    {   transports :: [Transport]
    ,   logLevel :: Int
    ,   heartbeats :: Bool
    } deriving Show

type Port = Int