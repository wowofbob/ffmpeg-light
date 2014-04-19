{-# LANGUAGE ForeignFunctionInterface, FlexibleContexts #-}
-- | Video decoding API. Includes FFI declarations for the underlying
-- FFmpeg functions, wrappers for these functions that wrap error
-- condition checking, and high level Haskellized interfaces.
module Codec.FFmpeg.Decode where
import Codec.FFmpeg.Common
import Codec.FFmpeg.Enums
import Codec.FFmpeg.Types
import Control.Applicative
import Control.Monad (when)
import Control.Monad.Error.Class
import Control.Monad.IO.Class
import Foreign.C.String
import Foreign.C.Types
import Foreign.Marshal.Alloc (alloca, free, mallocBytes)
import Foreign.Marshal.Array (advancePtr)
import Foreign.Marshal.Utils (with)
import Foreign.Ptr
import Foreign.Storable

-- * FFI Declarations

foreign import ccall "avformat_open_input" 
  avformat_open_input :: Ptr AVFormatContext -> CString -> Ptr ()
                      -> Ptr (Ptr ()) -> IO CInt

foreign import ccall "avformat_find_stream_info" 
  avformat_find_stream_info :: AVFormatContext -> Ptr () -> IO CInt

foreign import ccall "av_find_best_stream"
  av_find_best_stream :: AVFormatContext -> AVMediaType -> CInt -> CInt
                      -> Ptr AVCodec -> CInt -> IO CInt

foreign import ccall "avcodec_find_decoder"
   avcodec_find_decoder :: AVCodecID -> IO AVCodec

foreign import ccall "avcodec_find_decoder_by_name"
  avcodec_find_decoder_by_name :: CString -> IO AVCodec

foreign import ccall "avcodec_get_frame_defaults"
  avcodec_get_frame_defaults :: AVFrame -> IO ()

foreign import ccall "avpicture_get_size"
  avpicture_get_size :: AVPixelFormat -> CInt -> CInt -> IO CInt

foreign import ccall "av_malloc"
  av_malloc :: CSize -> IO (Ptr ())

foreign import ccall "av_read_frame"
  av_read_frame :: AVFormatContext -> AVPacket -> IO CInt

foreign import ccall "avcodec_decode_video2"
  decode_video :: AVCodecContext -> AVFrame -> Ptr CInt -> AVPacket
               -> IO CInt
foreign import ccall "avformat_close_input"
  close_input :: Ptr AVFormatContext -> IO ()

-- * FFmpeg Decoding Interface

-- | Open an input media file.
openInput :: (MonadIO m, Error e, MonadError e m) => String -> m AVFormatContext
openInput filename = 
  wrapIOError . alloca $ \ctx ->
    withCString filename $ \cstr ->
      do r <- avformat_open_input ctx cstr nullPtr nullPtr
         when (r /= 0) (errMsg "Error opening file")
         peek ctx

-- | @AVFrame@ is a superset of @AVPicture@, so we can upcast an
-- 'AVFrame' to an 'AVPicture'.
frameAsPicture :: AVFrame -> AVPicture
frameAsPicture = AVPicture . getPtr

-- | Find a codec given by name.
findDecoder :: (MonadIO m, Error e, MonadError e m) => String -> m AVCodec
findDecoder name = 
  do r <- liftIO $ withCString name avcodec_find_decoder_by_name
     when (getPtr r == nullPtr)
          (errMsg $ "Unsupported codec: " ++ show name)
     return r

-- | Read packets of a media file to get stream information. This is
-- useful for file formats with no headers such as MPEG.
checkStreams :: (MonadIO m, Error e, MonadError e m) => AVFormatContext -> m ()
checkStreams ctx = 
  do r <- liftIO $ avformat_find_stream_info ctx nullPtr
     when (r < 0) (errMsg "Couldn't find stream information")

-- | Searches for a video stream in an 'AVFormatContext'. If one is
-- found, returns the index of the stream in the container, and its
-- associated 'AVCodecContext' and 'AVCodec'.
findVideoStream :: (MonadIO m, Error e, MonadError e m)
                => AVFormatContext -> m (CInt, AVCodecContext, AVCodec)
findVideoStream fmt = do
  wrapIOError . alloca $ \codec -> do
      poke codec (AVCodec nullPtr)
      i <- av_find_best_stream fmt avmediaTypeVideo (-1) (-1) codec 0
      when (i < 0) (errMsg "Couldn't find a video stream")
      cod <- peek codec
      streams <- getStreams fmt
      vidStream <- peek (advancePtr streams (fromIntegral i))
      ctx <- getCodecContext vidStream
      return (i, ctx, cod)

-- | Find a registered decoder with a codec ID matching that found in
-- the given 'AVCodecContext'.
getDecoder :: (MonadIO m, Error e, MonadError e m)
           => AVCodecContext -> m AVCodec
getDecoder ctx = do p <- liftIO $ getCodecID ctx >>= avcodec_find_decoder
                    when (getPtr p == nullPtr) (errMsg "Unsupported codec")
                    return p

-- | Initialize the given 'AVCodecContext' to use the given
-- 'AVCodec'. **NOTE**: This function is not thread safe!
openCodec :: (MonadIO m, Error e, MonadError e m)
          => AVCodecContext -> AVCodec -> m AVDictionary
openCodec ctx cod = 
  wrapIOError . alloca $ \dict -> do
    poke dict (AVDictionary nullPtr)
    r <- open_codec ctx cod dict
    when (r < 0) (errMsg "Couldn't open decoder")
    peek dict

-- | Return the next frame of a stream.
read_frame_check :: AVFormatContext -> AVPacket -> IO ()
read_frame_check ctx pkt = do r <- av_read_frame ctx pkt
                              when (r < 0) (errMsg "Frame read failed")

-- | Read RGB frames from a video stream.
frameReader :: (MonadIO m, Error e, MonadError e m)
            => FilePath -> m (IO (Maybe AVFrame), IO ())
frameReader fileName =
  do inputContext <- openInput fileName
     checkStreams inputContext
     (vidStreamIndex, ctx, cod) <- findVideoStream inputContext
     _ <- openCodec ctx cod
     prepareReader inputContext vidStreamIndex ctx

-- | Read time stamped RGB frames from a video stream. Time is given
-- in seconds from the start of the stream.
frameReaderTime :: (MonadIO m, Error e, MonadError e m)
                => FilePath -> m (IO (Maybe (AVFrame, Double)), IO ())
frameReaderTime fileName =
  do inputContext <- openInput fileName
     checkStreams inputContext
     (vidStreamIndex, ctx, cod) <- findVideoStream inputContext
     _ <- openCodec ctx cod
     (reader, cleanup) <- prepareReader inputContext vidStreamIndex ctx
     AVRational num den <- liftIO $ getTimeBase ctx
     let (numl, dend) = (fromIntegral num, fromIntegral den)
         frameTime' frame = 
           do n <- getPts frame
              return $ fromIntegral (n * numl) / dend
         readTS = do frame <- reader
                     case frame of
                       Nothing -> return Nothing
                       Just f -> do t <- frameTime' f
                                    return $ Just (f, t)
     return (readTS, cleanup)

-- | Construct an action that gets the next available frame, and an
-- action to release all resources associated with this video stream.
prepareReader :: (MonadIO m, Error e, MonadError e m)
              => AVFormatContext -> CInt -> AVCodecContext
              -> m (IO (Maybe AVFrame), IO ())
prepareReader fmtCtx vidStream codCtx =
  wrapIOError $
  do fRaw <- frame_alloc_check
     fRgb <- frame_alloc_check

     w <- getWidth codCtx
     h <- getHeight codCtx
     fmt <- getPixelFormat codCtx

     setWidth fRgb w
     setHeight fRgb h
     setPixelFormat fRgb avPixFmtRgb24

     frame_get_buffer_check fRgb 32

     sws <- sws_getCachedContext (SwsContext nullPtr) 
              w h fmt
              w h avPixFmtRgb24
              swsBilinear
              nullPtr nullPtr nullPtr

     pkt <- AVPacket <$> mallocBytes packetSize
     let cleanup = do with fRgb av_frame_free
                      with fRaw av_frame_free
                      _ <- codec_close codCtx
                      with fmtCtx close_input
                      free (getPtr pkt)
         getFrame = do
           read_frame_check fmtCtx pkt
           whichStream <- getStreamIndex pkt
           if whichStream == vidStream
           then do
             fin <- alloca $ \finished -> do
                      _ <- decode_video codCtx fRaw finished pkt
                      peek finished
             if fin > 0
             then do
               -- Some streaming codecs require a final flush with
               -- an empty packet
               -- fin' <- alloca $ \fin2 -> do
               --           free_packet pkt
               --           (#poke AVPacket, data) pkt nullPtr
               --           (#poke AVPacket, size) pkt (0::CInt)
               --           decode_video codCtx fRaw fin2 pkt
               --           peek fin2
               let frameData = castPtr $ hasData fRaw
                   lnSize = hasLineSize fRaw
                   rgbData = castPtr $ hasData fRgb
                   rgbLnSize = hasLineSize fRgb

               _ <- sws_scale sws frameData lnSize 0 h rgbData rgbLnSize

               -- Copy the raw frame's timestamp to the RGB frame
               getPktPts fRaw >>= setPts fRgb

               free_packet pkt
               return $ Just fRgb
             else free_packet pkt >> getFrame
           else free_packet pkt >> getFrame
     return (getFrame `catchError` const (return Nothing), cleanup)