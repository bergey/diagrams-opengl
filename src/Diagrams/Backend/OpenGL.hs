{-# LANGUAGE DeriveDataTypeable    #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE ViewPatterns               #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE RankNTypes #-}

module Diagrams.Backend.OpenGL where

-- General  Haskell
import Data.Semigroup
import Control.Monad.State
import System.IO.Unsafe
import           Data.Typeable
import qualified Data.Vector.Storable as V
import Data.Tuple

-- Graphics
import Data.Colour.SRGB
import qualified Graphics.Rendering.OpenGL as GL
import Graphics.Rendering.OpenGL (($=))

-- From Diagrams
import Diagrams.Prelude hiding (Attribute, close, e, (<>))
import Diagrams.TwoD.Arc
import Diagrams.TwoD.Path
import Graphics.Rendering.Util

{- Points calculation-}

calcLines :: [Double] -> Double -> LineCap -> LineJoin -> [P2] -> [[P2]]
calcLines darr lwf lcap lj ps@(_:_:_) =
  case darr of
    []    -> map (calcLine lwf) lines <>
             map (calcJoin lj lwf) joins
    (_:_) -> calcDashedLines (cycle darr) False lwf lcap lj lines
  <> if dist < 0.0001
     then [calcJoin lj lwf (pup, fp, sp)]
     else [calcCap lwf lcap $ swap $ head lines] <>
          [calcCap lwf lcap $ last lines]
 where lines = zip  ps (tail ps)
       joins = zip3 ps (tail ps) (tail $ tail ps)
       pup   = ps !! (length ps - 2)
       lp    = last ps
       fp    = head ps
       sp    = ps !! 1
       dist = magnitude $ lp .-. fp
calcLines _ _ _ _ _ = mempty

calcDashedLines :: [Double] -> Bool -> Double -> LineCap -> LineJoin -> [(P2, P2)] -> [[P2]]
calcDashedLines (d:ds) hole lwf lcap lj ((p1, p2):ps) =
  if hole
  then if len >= d
       then calcDashedLines ds           (not hole) lwf lcap lj ((p1 .+^ vec, p2):ps)
       else calcDashedLines (d - len:ds) (    hole) lwf lcap lj ps
  else if len >= d
       then calcLine lwf (p1, p1 .+^ vec):
            calcDashedLines ds           (not hole) lwf lcap lj ((p1 .+^ vec, p2):ps)
       else calcLine lwf (p1, p2):
            case ps of
              ((_, p3):_) -> calcJoin lj lwf (p1, p2, p3):
                             calcDashedLines (d - len:ds) hole lwf lcap lj ps
              []     -> mempty
 where len = magnitude (p2 .-. p1)
       vec = normalized (p2 .-. p1) ^* d
calcDashedLines _ _ _ _ _ _ = mempty

calcCap :: Double -> LineCap -> (P2, P2) -> [P2]
calcCap lwf lcap (p1, p2) =
  case lcap of
    LineCapButt   -> mempty
    LineCapRound  ->
      trlVertices (p2 .+^ c, arcT (Rad $ -tau/4) (Rad $ tau/4)
                             # scale (realToFrac lwf/2) # rotate angle)
    LineCapSquare -> [ p2 .+^ c
                     , p2 .-^ c
                     , p2 .+^ (norm - c)
                     , p2 .+^ (norm + c)
                     ]
 where vec   = p2 .-. p1
       norm  = normalized vec ^* (lwf/2)
       c = rotate (-tau/4 :: Rad) norm
       angle :: Rad
       angle = direction vec

calcJoin :: LineJoin -> Double -> (P2, P2, P2) -> [P2]
calcJoin lj lwf (p1, p2, p3) =
  case lj of
    LineJoinMiter -> if abs spikeLength > 10 * lwf
                       then bevel
                       else spike
    LineJoinRound -> (p2:) $ case side of
      1 -> trlVertices (p2 .+^ v1, arc' (lwf/2) (direction v1 :: Rad) (direction v2))
      _ -> trlVertices (p2 .+^ v2, arc' (lwf/2) (direction v2 :: Rad) (direction v1))
    LineJoinBevel -> bevel
 where norm1       = normalized (p2 .-. p1) ^* (lwf/2)
       norm2       = normalized (p3 .-. p2) ^* (lwf/2)
       side        = if detV norm1 norm2 > 0
                       then  1
                       else -1
       v1 :: R2
       v1          = rotate (side * (-tau/4)::Rad) norm1
       v2 :: R2
       v2          = rotate (side * (-tau/4)::Rad) norm2
       bevel       = [ p2 .+^ v1
                     , p2 .+^ v2
                     , p2
                     ]
       spikeAngle  = (direction v1 - direction v2) / 2
       spikeLength = (lwf/2) / cos (getRad spikeAngle)
       v3 :: R2
       v3          = rotate (direction v1 - spikeAngle) unitX ^* spikeLength
       spike       = [ p2 .+^ v1
                     , p2 .+^ v3
                     , p2 .+^ v2
                     , p2
                     ]
       -- | The determinant of two vectors.
       detV :: R2 -> R2 -> Double
       detV (unr2 -> (x1,y1)) (unr2 -> (x2,y2)) = x1 * y2 - y1 * x2


calcLine :: Double -> (P2, P2) -> [P2]
calcLine lwf (p1, p2) =
  [ p1 .-^ c
  , p1
  , p1 .+^ c
  , p2 .+^ c
  , p2
  , p2 .-^ c
  ]
 where vec   = p2 .-. p1
       norm  = normalized vec ^* (lwf/2)
       c = rotate (-tau/4 :: Rad) norm

renderPath :: Path R2 -> Render OpenGL R2
renderPath p@(Path trs) =
  GlRen box $ do
    fc <- gets currentFillColor
    lc <- gets currentLineColor
    o <- gets currentOpacity
    fr <- gets currentFillRule
    lw <- gets currentLineWidth
    lcap <- gets currentLineCap
    lj <- gets currentLineJoin
    darr <- gets currentDashArray
    doff <- gets currentDashOffset
    clip <- gets currentClip
    put initialGLRenderState
    return $
      map (renderPolygon fc o) (clippedPolygons (simplePolygons fr) clip) <>
      map (renderPolygon lc o) (clippedPolygons (linePolygons darr lw lcap lj) clip)
 where trails                  = map trlVertices trs
       simplePolygons fr       = tessRegion fr trails

       linePolygons :: [Double] -> Double -> LineCap -> LineJoin -> [[P2]]
       linePolygons darr lw lcap lj = concatMap (calcLines darr lw lcap lj) trails

       clippedPolygons vis [] = vis
       clippedPolygons vis clip = concatMap (tessRegion GL.TessWindingAbsGeqTwo . (: clip)) vis
       box = boundingBox p

renderPolygon :: AlphaColour Double -> Double -> [P2] -> GlPrim
renderPolygon c o ps = GlPrim GL.TriangleFan (dissolve o c) vertices
  where vertices = V.fromList $ concatMap flatP2 ps

trlVertices :: (P2, Trail R2) -> [P2]
trlVertices (p0, t) =
  vertices <> if isClosed t && (magnitude (p0 .-. lp) > 0.0001)
              then [p0]
              else mempty
  where vertices = concat $ zipWith segVertices
                   (trailVertices p0 t) (trailSegments t ++ [straight (0 & 0)])
        lp = last $ trailVertices p0 t

segVertices :: P2 -> Segment R2 -> [P2]
segVertices p (Linear _) = [p]
segVertices p cubic = map ((p .+^) . atParam cubic) [0,i..1-i] where
  i = 1/30

tessRegion :: GL.TessWinding -> [[P2]] -> [[P2]]
tessRegion fr ps = renderTriangulation $ unsafePerformIO $
  GL.triangulate fr 0.0001 (GL.Normal3 0 0 0)
    (\_ (GL.WeightedProperties (_,p) _ _ _) -> p) $
    GL.ComplexPolygon [GL.ComplexContour (map createVertex p) | p <- ps]
 where createVertex (unp2 -> (x,y)) =
          GL.AnnotatedVertex (GL.Vertex3 (realToFrac x) (realToFrac y) 0)
                            (0::Int)
       renderTriangulation (GL.Triangulation ts) =
         map renderTriangle ts
       renderTriangle (GL.Triangle
                       (GL.AnnotatedVertex (GL.Vertex3 x0 y0 _) _)
                       (GL.AnnotatedVertex (GL.Vertex3 x1 y1 _) _)
                       (GL.AnnotatedVertex (GL.Vertex3 x2 y2 _) _)
                      ) = [ p2 (realToFrac x0, realToFrac y0)
                          , p2 (realToFrac x1, realToFrac y1)
                          , p2 (realToFrac x2, realToFrac y2)
                          ]

flatP2 :: (Fractional a, Num a) => P2 -> [a]
flatP2 (unp2 -> (x,y)) = [r2f x, r2f y]

data OpenGL = OpenGL
            deriving (Show, Typeable)

data GLRenderState =
  GLRenderState{ currentLineColor  :: AlphaColour Double
               , currentFillColor  :: AlphaColour Double
               , currentOpacity    :: Double
               , currentLineWidth  :: Double
               , currentLineCap    :: LineCap
               , currentLineJoin   :: LineJoin
               , currentFillRule   :: GL.TessWinding
               , currentDashArray  :: [Double]
               , currentDashOffset :: Double
               , currentClip       :: [[P2]]
               }

initialGLRenderState :: GLRenderState
initialGLRenderState = GLRenderState
                            (opaque black)
                            transparent
                            1
                            0.01
                            LineCapButt
                            LineJoinMiter
                            GL.TessWindingNonzero
                            []
                            0
                            []

type GLRenderM a = State GLRenderState a

instance Backend OpenGL R2 where
  data Render OpenGL R2 = GlRen (BoundingBox R2) (GLRenderM [GlPrim])
  type Result OpenGL R2 = IO ()
  data Options OpenGL R2 = GlOptions
                           { bgColor :: AlphaColour Double -- ^ The clear color for the window
                           }
                         deriving Show
  withStyle _ s _ (GlRen b p) =
      GlRen b $ do
        mapM_ ($ s)
          [ changeLineColor
          , changeFillColor
          , changeOpacity
          , changeLineWidth
          , changeLineCap
          , changeLineJoin
          , changeFillRule
          , changeDashing
          , changeClip
          ]
        p

-- | The OpenGL backend expects doRender to be called in a loop.
--   Ideally, most of the work would be done on the first rendering,
--   and subsequent renderings should require very little CPU computation
  doRender _ o (GlRen b p) = do
    GL.clearColor $= glColor (bgColor o)
    GL.clear [GL.ColorBuffer]
    GL.matrixMode $= GL.Modelview 0
    GL.loadIdentity
    inclusiveOrtho b
    let ps = evalState p initialGLRenderState
    -- GL.polygonMode $= (GL.Line, GL.Line)
    GL.blend $= GL.Enabled
    GL.blendFunc $= (GL.SrcAlpha, GL.OneMinusSrcAlpha)
    mapM_ (drawOGL 2) ps
    GL.flush

instance Monoid (Render OpenGL R2) where
  mempty = GlRen emptyBox $ return mempty
  (GlRen b1 p01) `mappend` (GlRen b2 p02) =
    GlRen (b1 <> b2) $ do
      p1 <- p01
      p2 <- p02
      return $ p1 <> p2

instance Renderable (Path R2) OpenGL where
  render _ = renderPath

instance Renderable (Trail R2) OpenGL where
  render c t = render c $ Path [(p2 (0,0), t)]

instance Renderable (Segment R2) OpenGL where
  render c = render c . flip Trail False . (:[])

dimensions :: QDiagram b R2 m -> (Double, Double)
dimensions = unr2 . boxExtents . boundingBox

aspectRatio :: QDiagram b R2 m -> Double
aspectRatio = uncurry (/) . dimensions

inclusiveOrtho :: BoundingBox R2 -> IO ()
inclusiveOrtho b = GL.ortho x0 x1 y0 y1 z0 z1 where
  defaultBounds = (p2 (-1,-1), p2 (1,1))
  ext      = unr2 $ boxExtents b
  (ll, ur) = maybe defaultBounds id $ getCorners b
  (x0, y0) = r2fPr $ unp2 ll - 0.05 * ext
  (x1, y1) = r2fPr $ unp2 ur + 0.05 * ext
  z0 = 0
  z1 = 1

{- Style changes -}

changeLineColor :: Style v -> GLRenderM ()
changeLineColor s =
  case lcol of
    Just (r, g, b, a) ->
      modify $ \st -> st{currentLineColor = withOpacity (sRGB r g b) a}
    Nothing           -> return ()
 where lcol = colorToRGBA <$> getLineColor <$> getAttr s

changeFillColor :: Style v -> GLRenderM ()
changeFillColor s =
  case fcol of
    Just (r, g, b, a) ->
      modify $ \st -> st{currentFillColor = withOpacity (sRGB r g b) a}
    Nothing           -> return ()
 where fcol = colorToRGBA <$> getFillColor <$> getAttr s

changeOpacity :: Style v -> GLRenderM ()
changeOpacity s =
  case op of
    Just o -> modify $ \st -> st{currentOpacity = o}
    Nothing           -> return ()
 where op =  getOpacity <$> getAttr s

changeLineWidth :: Style v -> GLRenderM ()
changeLineWidth s =
  case lwid of
    Just a  -> modify $ \st -> st{currentLineWidth = realToFrac a}
    Nothing -> return ()
 where lwid = getLineWidth <$> getAttr s

changeLineCap :: Style v -> GLRenderM ()
changeLineCap s =
  case lcap of
    Just a  -> modify $ \st -> st{currentLineCap = a}
    Nothing -> return ()
 where lcap = getLineCap <$> getAttr s

changeLineJoin:: Style v -> GLRenderM ()
changeLineJoin s =
  case lj of
    Just a  -> modify $ \st -> st{currentLineJoin = a}
    Nothing -> return ()
 where lj = getLineJoin <$> getAttr s

changeFillRule :: Style v -> GLRenderM ()
changeFillRule s =
  case fr of
    Just Winding -> modify $ \st -> st{currentFillRule = GL.TessWindingNonzero}
    Just EvenOdd -> modify $ \st -> st{currentFillRule = GL.TessWindingOdd}
    Nothing      -> return ()
 where fr = getFillRule <$> getAttr s

changeDashing :: Style v -> GLRenderM ()
changeDashing s =
  case dash of
    Just (Dashing a o) ->
      modify $ \st ->
      st{ currentDashArray  = map realToFrac a
        , currentDashOffset = realToFrac o
        }
    Nothing      -> return ()
 where dash = getDashing <$> getAttr s

changeClip :: Style v -> GLRenderM ()
changeClip s =
  case clip of
    Just (Path trs:_) ->
      modify $ \st ->
      st{ currentClip = tessRegion GL.TessWindingNonzero $
                        map trlVertices trs
        }
    Just _       -> return ()
    Nothing      -> return ()
 where clip = getClip <$> getAttr s
