module Main where

import Graphics.Vty

import Control.Applicative
import Control.Arrow
import Control.Monad.RWS

import Data.Default (def)
import Data.Sequence (Seq, (<|) )
import qualified Data.Sequence as Seq
import Data.Foldable

event_buffer_size = 1000

type App = RWST Vty () (Seq String) IO

main = do
    vty <- mkVty def
    _ <- execRWST (vty_interact False) vty Seq.empty
    shutdown vty

vty_interact :: Bool -> App ()
vty_interact should_exit = do
    update_display
    unless should_exit $ handle_next_event >>= vty_interact

update_display :: App ()
update_display = do
    let info = string def_attr "Press ESC to exit."
    event_log <- foldMap (string def_attr) <$> get
    let pic = pic_for_image $ info <-> event_log
    vty <- ask
    liftIO $ update vty pic

handle_next_event = ask >>= liftIO . next_event >>= handle_event
    where
        handle_event e               = do
            modify $ (<|) (show e) >>> Seq.take event_buffer_size
            return $ e == EvKey KEsc []

