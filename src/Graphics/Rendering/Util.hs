module Graphics.Rendering.Util where

-- Wrap OpenGL calls in a slightly more declarative syntax
-- TODO more consistent naming

import Data.Colour
import Foreign.Ptr
import Foreign.Storable
import System.IO
import qualified Data.Vector.Storable as V

import Diagrams.Attributes
import Graphics.Rendering.OpenGL

data GlPrim = GlPrim {
  primMode  :: PrimitiveMode,
  primColor :: (AlphaColour Double),
  primVec   :: (V.Vector GLfloat) }

instance Show GlPrim where
  show (GlPrim mode c v) = concat ["GlPrim ", show mode, " ", show c, " ", show v]

initProgram :: String -> String -> IO Program
initProgram v f = do
  [vSh] <-  genObjectNames 1
  [fSh] <- genObjectNames 1
  shaderSource vSh $= [v]
  shaderSource fSh $= [f]
  compileShader vSh
  compileShader fSh

  [shProg] <- genObjectNames 1
  attachedShaders shProg $= ([vSh], [fSh])
  linkProgram shProg
  return shProg

-- | Load a vertex shader and a fragment shader from the specified files
loadShaders :: String -> String -> IO Program
loadShaders vFile fFile = do
  withFile vFile ReadMode $ \vHandle -> do
    withFile fFile ReadMode $ \fHandle -> do
      vText <- hGetContents vHandle
      fText <- hGetContents fHandle
      initProgram vText fText

-- TODO wrap output with info about length, foor use in render
initGeometry :: Storable a => V.Vector a -> IO BufferObject
initGeometry tris = do
  [vbo] <- genObjectNames 1
  bindBuffer ArrayBuffer $= Just vbo
  let len = fromIntegral $ V.length tris  * sizeOf (V.head tris)
  V.unsafeWith tris $ \ptr ->
    bufferData ArrayBuffer $= (len, ptr, StaticDraw)
  return vbo

bindVao :: BufferObject -> IO VertexArrayObject
bindVao vb = do
  [vao] <- genObjectNames 1
  bindVertexArrayObject $= Just vao
  vertexAttribArray (AttribLocation 0)  $= Enabled
  bindBuffer ArrayBuffer $= Just vb
  vertexAttribPointer (AttribLocation 0) $= (ToFloat, VertexArrayDescriptor 3 Float 0 nullPtr)
  return vao

-- | Convert a haskell / diagrams color to OpenGL
--   TODO be more correct about color space
glColor :: (Real a, Floating a, Fractional b) => AlphaColour a -> Color4 b
glColor c = Color4 r g b a where
  (r,g,b,a) = r2fQuad $ colorToSRGBA c

drawOGL :: NumComponents -> GlPrim -> IO ()
drawOGL dims (GlPrim mode c v) = draw dims mode c v

-- | The first argument is the number of coördinates given for each vertex
--   2 and 3 are readily interpreted; 4 indicates homogeneous 3D coördinates
draw :: (Real c, Floating c) => NumComponents -> PrimitiveMode -> AlphaColour c -> V.Vector GLfloat -> IO ()
draw dims mode c pts = do
  color $ (glColor c :: Color4 GLfloat) -- all vertices same color
  V.unsafeWith pts $ \ptr -> do
    arrayPointer VertexArray $= VertexArrayDescriptor dims Float 0 ptr

  drawArrays mode 0 ptCount where
    ptCount = fromIntegral $ V.length pts `quot` (fromIntegral dims)

r2f :: (Real r, Fractional f) => r -> f
r2f x = realToFrac x

r2fPr :: (Real r, Fractional f) => (r,r) -> (f,f)
r2fPr (a,b) = (r2f a, r2f b)

r2fQuad :: (Real r, Fractional f) => (r,r,r,r) -> (f,f,f,f)
r2fQuad (a,b,c,d) = (r2f a, r2f b, r2f c, r2f d)
