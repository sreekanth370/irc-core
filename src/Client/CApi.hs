{-# Language RecordWildCards #-}
{-|
Module      : Client.CApi
Description : Dynamically loaded extension API
Copyright   : (c) Eric Mertens, 2016
License     : ISC
Maintainer  : emertens@gmail.com

Foreign interface to the IRC client via a simple C API
and dynamically loaded modules.

-}

module Client.CApi
  ( ActiveExtension(..)
  , extensionSymbol
  , activateExtension
  , deactivateExtension
  , notifyExtensions
  , commandExtension
  , withStableMVar
  ) where

import           Client.CApi.Types
import           Client.ChannelState
import           Client.ConnectionState
import           Client.Message
import           Client.State
import           Control.Concurrent.MVar
import           Control.Exception
import           Control.Lens
import           Control.Monad
import           Control.Monad.Trans.Class
import           Control.Monad.Trans.Cont
import           Data.Foldable
import qualified Data.HashMap.Strict as HashMap
import           Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Foreign as Text
import           Data.Time
import           Foreign.C
import           Foreign.Marshal
import           Foreign.Ptr
import           Foreign.StablePtr
import           Foreign.Storable
import           Irc.Identifier
import           Irc.RawIrcMsg
import           Irc.UserInfo
import           System.Posix.DynamicLinker

------------------------------------------------------------------------

-- | Type stored in the 'StablePtr' passed through the C API
type ApiState = MVar ClientState

------------------------------------------------------------------------

-- | The symbol that is loaded from an extension object.
--
-- Extensions are expected to export:
--
-- @
-- struct galua_extension extension;
-- @
extensionSymbol :: String
extensionSymbol = "extension"

-- | Information about a loaded extension including the handle
-- to the loaded shared object, and state value returned by
-- the startup callback, and the loaded extension record.
data ActiveExtension = ActiveExtension
  { aeFgn     :: !FgnExtension -- ^ Struct of callback function pointers
  , aeDL      :: !DL           -- ^ Handle of dynamically linked extension
  , aeSession :: !(Ptr ())       -- ^ State value generated by start callback
  , aeName    :: !Text
  , aeMajorVersion, aeMinorVersion :: !Int
  }

-- | Load the extension from the given path and call the start
-- callback. The result of the start callback is saved to be
-- passed to any subsequent calls into the extension.
activateExtension ::
  Ptr () ->
  FilePath {- ^ path to extension -} ->
  IO ActiveExtension
activateExtension stab path =
  do dl   <- dlopen path [RTLD_NOW, RTLD_LOCAL]
     p    <- dlsym dl extensionSymbol
     fgn  <- peek (castFunPtrToPtr p)
     name <- peekCString (fgnName fgn)
     let f = fgnStart fgn
     s  <- if nullFunPtr == f
             then return nullPtr
             else withCString path (runStartExtension f stab)
     return $! ActiveExtension
       { aeFgn     = fgn
       , aeDL      = dl
       , aeSession = s
       , aeName    = Text.pack name
       , aeMajorVersion = fromIntegral (fgnMajorVersion fgn)
       , aeMinorVersion = fromIntegral (fgnMinorVersion fgn)
       }

-- | Call the stop callback of the extension if it is defined
-- and unload the shared object.
deactivateExtension :: Ptr () -> ActiveExtension -> IO ()
deactivateExtension stab ae =
  do let f = fgnStop (aeFgn ae)
     unless (nullFunPtr == f) $
       (runStopExtension f stab (aeSession ae))
     dlclose (aeDL ae)

-- | Call all of the process message callbacks in the list of extensions.
-- This operation marshals the IRC message once and shares that across
-- all of the callbacks.
notifyExtensions ::
  Ptr () {- ^ clientstate stable pointer -} ->
  Text              {- ^ network              -} ->
  RawIrcMsg         {- ^ current message      -} ->
  [ActiveExtension] ->
  IO ()
notifyExtensions stab network msg aes
  | null aes' = return ()
  | otherwise = evalContT doNotifications
  where
    aes' = [ (f,s) | ae <- aes
                  , let f = fgnMessage (aeFgn ae)
                        s = aeSession ae
                  , f /= nullFunPtr ]

    doNotifications :: ContT () IO ()
    doNotifications =
      do msgPtr <- withRawIrcMsg network msg
         (f,s)  <- ContT $ for_ aes'
         lift $ runProcessMessage f stab s msgPtr

commandExtension ::
  Ptr ()          {- ^ client state stableptr -} ->
  [Text]          {- ^ parameters             -} ->
  ActiveExtension {- ^ extension to command   -} ->
  IO ()
commandExtension stab params ae = evalContT $
  do cmd <- withCommand params
     let f = fgnCommand (aeFgn ae)
     lift $ unless (f == nullFunPtr)
          $ runProcessCommand f stab (aeSession ae) cmd

-- | Create a 'StablePtr' around a 'MVar' which will be valid for the remainder
-- of the computation.
withStableMVar :: a -> (Ptr () -> IO b) -> IO (a,b)
withStableMVar x k =
  do mvar <- newMVar x
     res <- bracket (newStablePtr mvar) freeStablePtr (k . castStablePtrToPtr)
     x' <- takeMVar mvar
     return (x', res)

-- | Marshal a 'RawIrcMsg' into a 'FgnMsg' which will be valid for
-- the remainder of the computation.
withRawIrcMsg ::
  Text                 {- ^ network      -} ->
  RawIrcMsg            {- ^ message      -} ->
  ContT a IO (Ptr FgnMsg)
withRawIrcMsg network RawIrcMsg{..} =
  do net     <- withText network
     pfxN    <- withText $ maybe Text.empty (idText.userNick) _msgPrefix
     pfxU    <- withText $ maybe Text.empty userName _msgPrefix
     pfxH    <- withText $ maybe Text.empty userHost _msgPrefix
     cmd     <- withText _msgCommand
     prms    <- traverse withText _msgParams
     tags    <- traverse withTag  _msgTags
     let (keys,vals) = unzip tags
     (tagN,keysPtr) <- contT2 $ withArrayLen keys
     valsPtr        <- ContT  $ withArray vals
     (prmN,prmPtr)  <- contT2 $ withArrayLen prms
     ContT $ with $ FgnMsg net pfxN pfxU pfxH cmd prmPtr (fromIntegral prmN)
                                       keysPtr valsPtr (fromIntegral tagN)

withCommand ::
  [Text] {- ^ parameters -} ->
  ContT a IO (Ptr FgnCmd)
withCommand params =
  do prms          <- traverse withText params
     (prmN,prmPtr) <- contT2 $ withArrayLen prms
     ContT $ with $ FgnCmd prmPtr (fromIntegral prmN)

withTag :: TagEntry -> ContT a IO (FgnStringLen, FgnStringLen)
withTag (TagEntry k v) =
  do pk <- withText k
     pv <- withText v
     return (pk,pv)

withText :: Text -> ContT a IO FgnStringLen
withText txt =
  do (ptr,len) <- ContT $ Text.withCStringLen txt
     return $ FgnStringLen ptr $ fromIntegral len

contT2 :: ((a -> b -> m c) -> m c) -> ContT c m (a,b)
contT2 f = ContT $ \g -> f $ curry g

------------------------------------------------------------------------

-- | Import a 'FgnMsg' into an 'RawIrcMsg'
peekFgnMsg :: FgnMsg -> IO RawIrcMsg
peekFgnMsg FgnMsg{..} =
  do let strArray n p = traverse peekFgnStringLen =<<
                        peekArray (fromIntegral n) p

     tagKeys <- strArray fmTagN fmTagKeys
     tagVals <- strArray fmTagN fmTagVals
     prefixN  <- peekFgnStringLen fmPrefixNick
     prefixU  <- peekFgnStringLen fmPrefixUser
     prefixH  <- peekFgnStringLen fmPrefixHost
     command <- peekFgnStringLen fmCommand
     params  <- strArray fmParamN fmParams

     return RawIrcMsg
       { _msgTags    = zipWith TagEntry tagKeys tagVals
       , _msgPrefix  = if Text.null prefixN
                         then Nothing
                         else Just (UserInfo (mkId prefixN) prefixU prefixH)
       , _msgCommand = command
       , _msgParams  = params
       }

-- | Peek a 'FgnStringLen' as UTF-8 encoded bytes.
peekFgnStringLen :: FgnStringLen -> IO Text
peekFgnStringLen (FgnStringLen ptr len) =
  Text.peekCStringLen (ptr, fromIntegral len)

------------------------------------------------------------------------

type CApiSendMessage = Ptr () -> Ptr FgnMsg -> IO CInt

foreign export ccall "glirc_send_message" capiSendMessage :: CApiSendMessage

capiSendMessage :: CApiSendMessage
capiSendMessage stPtr msgPtr =
  do mvar    <- deRefStablePtr (castPtrToStablePtr stPtr) :: IO ApiState
     fgn     <- peek msgPtr
     msg     <- peekFgnMsg fgn
     network <- peekFgnStringLen (fmNetwork fgn)
     withMVar mvar $ \st ->
       case preview (clientConnection network) st of
         Nothing -> return 1
         Just cs -> do sendMsg cs msg
                       return 0
  `catch` \SomeException{} -> return 1

------------------------------------------------------------------------

type CApiPrint = Ptr () -> CInt -> CString -> CSize -> IO CInt

foreign export ccall "glirc_print" capiPrint :: CApiPrint

capiPrint :: CApiPrint
capiPrint stPtr code msgPtr msgLen =
  do mvar <- deRefStablePtr (castPtrToStablePtr stPtr) :: IO ApiState
     txt  <- Text.peekCStringLen (msgPtr, fromIntegral msgLen)
     now  <- getZonedTime

     let con | code == normalMessageCode = NormalBody
             | otherwise                 = ErrorBody
         msg = ClientMessage
                 { _msgBody    = con txt
                 , _msgTime    = now
                 , _msgNetwork = Text.empty
                 }
     modifyMVar_ mvar $ \st ->
       do return (recordNetworkMessage msg st)
     return 0
  `catch` \SomeException{} -> return 1

------------------------------------------------------------------------

type CApiListNetworks = Ptr () -> IO (Ptr CString)

foreign export ccall "glirc_list_networks" capiListNetworks :: CApiListNetworks

capiListNetworks :: CApiListNetworks
capiListNetworks stab =
  do mvar <- deRefStablePtr (castPtrToStablePtr stab) :: IO ApiState
     st   <- readMVar mvar
     let networks = views clientNetworkMap HashMap.keys st
     strs <- traverse (newCString . Text.unpack) networks
     newArray0 nullPtr strs

------------------------------------------------------------------------

type CApiIdentifierCmp = CString -> CSize -> CString -> CSize -> IO CInt

foreign export ccall "glirc_identifier_cmp" capiIdentifierCmp :: CApiIdentifierCmp

capiIdentifierCmp :: CApiIdentifierCmp
capiIdentifierCmp p1 n1 p2 n2 =
  do txt1 <- Text.peekCStringLen (p1, fromIntegral n1)
     txt2 <- Text.peekCStringLen (p2, fromIntegral n2)
     return $! case compare (mkId txt1) (mkId txt2) of
                 LT -> -1
                 EQ ->  0
                 GT ->  1

------------------------------------------------------------------------

type CApiListChannels = Ptr () -> CString -> CSize -> IO (Ptr CString)

foreign export ccall "glirc_list_channels" capiListChannels :: CApiListChannels

capiListChannels :: CApiListChannels
capiListChannels stab networkPtr networkLen =
  do mvar <- deRefStablePtr (castPtrToStablePtr stab) :: IO ApiState
     st   <- readMVar mvar
     network <- Text.peekCStringLen (networkPtr, fromIntegral networkLen)
     case preview (clientConnection network . csChannels) st of
        Nothing -> return nullPtr
        Just m  ->
          do strs <- traverse (newCString . Text.unpack . idText) (HashMap.keys m)
             newArray0 nullPtr strs

------------------------------------------------------------------------

type CApiListChannelUsers = Ptr () -> CString -> CSize -> CString -> CSize -> IO (Ptr CString)

foreign export ccall "glirc_list_channel_users" capiListChannelUsers :: CApiListChannelUsers

capiListChannelUsers :: CApiListChannelUsers
capiListChannelUsers stab networkPtr networkLen channelPtr channelLen =
  do mvar <- deRefStablePtr (castPtrToStablePtr stab) :: IO ApiState
     st   <- readMVar mvar
     network <- Text.peekCStringLen (networkPtr, fromIntegral networkLen)
     channel <- Text.peekCStringLen (channelPtr, fromIntegral channelLen)
     let mb = preview ( clientConnection network
                      . csChannels . ix (mkId channel)
                      . chanUsers
                      ) st
     case mb of
       Nothing -> return nullPtr
       Just m  ->
         do strs <- traverse (newCString . Text.unpack . idText) (HashMap.keys m)
            newArray0 nullPtr strs

------------------------------------------------------------------------

type CApiMyNick =
  Ptr () ->
  CString {- ^ network name        -} ->
  CSize   {- ^ network name length -} ->
  IO CString

foreign export ccall "glirc_my_nick" capiMyNick :: CApiMyNick

capiMyNick :: CApiMyNick
capiMyNick stab networkPtr networkLen =
  do mvar <- deRefStablePtr (castPtrToStablePtr stab) :: IO ApiState
     st   <- readMVar mvar
     network <- Text.peekCStringLen (networkPtr, fromIntegral networkLen)
     let mb = preview (clientConnection network . csNick) st
     case mb of
       Nothing -> return nullPtr
       Just me -> newCString (Text.unpack (idText me))
