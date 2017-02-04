{-# LANGUAGE FlexibleContexts #-}
module Main where

import Codec.FFmpeg
import Codec.FFmpeg.Decode

import Control.Concurrent.MVar (newMVar, takeMVar, putMVar)
import Control.Monad.Except
import Control.Monad.Trans.Maybe

import Data.Text (Text)

import Foreign.C.Types

import qualified SDL as SDL


{- Wrapper for frameReaderTime which returns
   time difference between two adjecent frames.   
-}
frameReaderTimeDiff
  :: (MonadIO m, MonadError String m)
  => AVPixelFormat
  -> InputSource
  -> m (IO (Maybe (AVFrame, Double)), IO ())
frameReaderTimeDiff fmt src = do
  
  -- Get reader and cleanup.
  (getFrame, cleanup) <- frameReaderTime fmt src 
  
  -- Put zero time into variable.
  prevTimeVar <- liftIO $ newMVar 0.0
  
  -- Wrapper for reader.
  let getFrame' = runMaybeT $ do
  
        -- Get next frame.
        (frame, currTime) <- frameGet
      
        -- Get time of previous frame.
        prevTime <- prevTimeGet
        
        -- Set time of current frame.
        prevTimeSet currTime
                      
        -- Compute time difference.
        let timeDiff = currTime - prevTime
        
        -- Return frame and difference.
        return (frame, timeDiff)
        
        where
          
          -- Getter for frame.
          frameGet = MaybeT getFrame
          
          -- Getter for previous frame time.
          prevTimeGet = liftIO $ takeMVar prevTimeVar
          
          -- Setter for previous frame time.
          prevTimeSet = liftIO . putMVar prevTimeVar
          
  -- Return wrapper and original cleanup.
  return (getFrame', cleanup)


{- Wrapper for monads which returns Nothing when:

     1. Monad action returns Nothing. 
     2. When condition holds.
-}
nothingWhen
  :: Monad m
  => m a -> (a -> Bool) -> m (Maybe b) -> m (Maybe b)
nothingWhen g p action = do
  
  -- Generate conditional.
  a <- g
  
  -- Check predicate.
  if p a
    then return Nothing
    else action
      

{- Wrapper for IO action which returns Nothing when:

    1. Action by itself returns Nothing.
    2. If QuitEvent was received.

-}
nothingOnQuit
  :: MonadIO m
  => m (Maybe a) -> m (Maybe a)
nothingOnQuit action =
  nothingWhen
    SDL.pollEvents
    (not . null . filter
      (\ event ->
          case SDL.eventPayload event of 
            SDL.QuitEvent -> True
            _             -> False)) action
            
         
-- Configuration for video player.
data Config =
  Config {
    cfgDriver     :: CInt,
    cfgFmtFFmpeg  :: AVPixelFormat,
    cfgFmtSDL     :: SDL.PixelFormat,
    cfgWindowName :: Text
  }
            
videoPlayer
  :: (MonadIO m, MonadError String m)
  => Config -> InputSource -> m ()
videoPlayer cfg src = do
  
  {- Setup SDL. -}

  -- Initialize SDL.
  SDL.initializeAll
  
  -- Create window.
  window <- createWindow
  
  -- Get renderer associated with window.
  renderer <- createRenderer window


  {- Setup frame reader. -}

  -- Initialize FFmpeg.
  liftIO $ initFFmpeg
  
  -- Open input source for reading frames.
  (getFrame, cleanup) <- frameReader'
  
  
  {- Render frames. -}
  
  


  {- Cleanup. -}
    
  -- Cleanup after frame reading.
  liftIO cleanup
  
  -- Destroy renderer.
  SDL.destroyRenderer renderer
  
  -- Destroy window.
  SDL.destroyWindow window
  
  -- Quit SDL.
  SDL.quit 
  
  where
  
    createWindow     = SDL.createWindow (cfgWindowName cfg) SDL.defaultWindow
    createRenderer w = SDL.createRenderer w (cfgDriver cfg) SDL.defaultRenderer
    
    frameReader' = do
      (getFrame, cleanup) <- frameReaderTimeDiff (cfgFmtFFmpeg cfg) src
      return (nothingOnQuit getFrame, cleanup)
    
     

main :: IO ()
main = return ()