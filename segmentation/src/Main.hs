{-# OPTIONS_GHC -F -pgmF inlitpp #-}
```haskell hide top
import Inliterate.Import
```
```html_header
<script src="https://cdn.plot.ly/plotly-latest.min.js"></script>
```

# Segmentation
This module comprises the segmentation part of the preprocessing of the data, applying whats
described in the paper

> **Automatic segmentation of Phonocardiogram using the occurrence of the cardiac events**
> *Vishwanath et al., 2017*

*Required libraries*:

```haskell top
import Sound.File.Sndfile            as Snd
import Sound.File.Sndfile.Buffer.StorableVector as BV
import Data.Complex                  as Complex
import Data.Array                    as Array
import qualified Data.StorableVector as Vector
import DSP.Basic				     as DSP
import DSP.Window				     as DSP
import DSP.Filter.IIR.IIR            as DSP
import DSP.Filter.IIR.Design         as DSP
import Numeric.Transform.Fourier.FFT as FFT
import Graphics.Plotly			     as Plotly
import Graphics.Plotly.Lucid	     as Plotly
import Lucid						 as Lucid
import qualified Data.Text           as Text
import Data.StorableVector (Vector)
import Data.Function ((&))
import Data.Text (Text)
import Data.Monoid
```

## 1. Process

The process that is described in the paper can be mapped to the following commutative diagram:

$$\require{AMScd}$$

$$\begin{CD}
Noisy Sound @>prefilter>> Filtered Sound @>makeSpectrogram>> Spectrogram\\\\
@. @. @VV{barkscale}V\\\\
Event Detection Function @<loudnessEvaluation<< SmoothSpectrogram @<smoothen<< BarkScaled Spectrogram
\end{CD}$$


The [classes](https://en.wikipedia.org/wiki/Class_(set_theory))
in this commutative diagram can be represented directly as newtypes in Haskell:

```haskell top
newtype NoisySound             = NoisySound [Double]
newtype FilteredSound          = FilteredSound [Double]
newtype Spectrogram            = Spectrogram [Array Int Double]
newtype BarkScaledSpectrogram  = BarkScaledSpectrogram [Array Int Double]
newtype SmoothSpectrogram      = SmoothSpectrogram [Array Int Double]
newtype EventDetectionFunction = EventDetectionFunction [Double]
```

The [morphisms](https://en.wikipedia.org/wiki/Morphism) represented in the diagram are functions
that would transform the data in some way:

1. `prefilter` would apply a [Chebyshev type I Lowpass filter](https://en.wikipedia.org/wiki/Chebyshev_filter)
2. An `stft` would be applied to all the `FilteredSound` using a *3ms* [Hann Window](https://en.wikipedia.org/wiki/Window_function#Cosine-sum_windows)
3. `barkscale` scales the `Spectrogram` using a [Bark scale](https://en.wikipedia.org/wiki/Bark_scale)
4. `smoothen` convolves each of the frequency bands using a *200ms* Hanning window.
5. `loudnessEvaluation` sums all the amplitudes of all frequency bands
6. Now we convolute the loudness with a *300ms* Hamming window, so we obtain a smoothed loudness
	index function, where positive peaks are **onsets**, and negative ones are **offsets**
    
After doing this process, we can locate manually the \\(S_1\\) and \\(S_2\\) sounds, which help us
to locate the *systole* and *diastole*. After that, it's just a matter of alternation. So, we
can automate the segmentation of the next sounds.

## 2. Implementation

To implement the `prefilter` function, we can use the `dsp` package that comes with many
nice DSP functions that are helpful here.

```haskell top
prefilter :: NoisySound -> FilteredSound
prefilter (NoisySound ns) = FilteredSound filteredSound
  where
  	wp = 0.01
    rp = 1.0
    ws = 0.0111
    rs = 42
    (b, a) = DSP.chebyshev1Lowpass (wp, rp) (ws, rs)
    filteredSound = DSP.iir_df2 (b, a) ns
```


Now we can proceed to define `makeSpectrogram`, but first we need to separate all of our
samples in frames, and get their magnitudes:

```haskell top
getFrames :: Array Int Double -> Int -> Int -> [Array Int Double]
getFrames inArr frameSize hop =
     [getFrame inArr start frameSize | start <- [0, hop .. l-1]]
   where
     (_,l) = Array.bounds inArr
 
getFrame :: Array Int Double -> Int -> Int -> Array Int Double
getFrame inVect start len =
	DSP.pad slice len
  where
    slice = Array.ixmap (0, l - 1) (+ start) inVect
    l = min len (end - start)
    (_,end) = Array.bounds inVect

getFrameMagnitude :: Array Int (Complex Double) -> Array Int Double
getFrameMagnitude frame =
		Array.array (0,(l-1) `div` 2) 
        	[(i,log (magnitude (frame!(i+(l-1) `div` 2)) + 1))
            	| i <- [0..((l-1) `div` 2)]]
 	where
 		(_,l) = Array.bounds frame
```

Now, we define our `makeSpectrogram` function easily:

```haskell top
makeSpectrogram :: FilteredSound -> Spectrogram
makeSpectrogram (FilteredSound fs) = Spectrogram spectrogram
  where
    fsArray = Array.array (0, length fs) [(i, fs !! i) | i <- [0..(length fs)]]
    spectrogram = map (getFrameMagnitude . rfft) (getFrames fsArray 1024 512)
```

To make the `barkscale` function we just have to apply the following function to each
of the frequencies in our `Spectrogram`:

$$ z(f) = 13\ arctan(0.00076f)+3.5arctan(\frac{f}{7500^2}) $$

```haskell top
barkscaleFrequency :: Double -> Double
barkscaleFrequency f = 13.0 * atan (0.00076 * f) + 3.5 * atan (f/(7500^2))
```

For scaling our spectrogram, it is a matter of applying the function two levels deep
elementwise using `fmap`:

```haskell top
barkscale :: Spectrogram -> BarkScaledSpectrogram
barkscale (Spectrogram s) =
	BarkScaledSpectrogram $ (fmap . fmap) barkscaleFrequency s
```

Let's smoothen the spectrogram by using a hann window:

```haskell top
smoothen :: BarkScaledSpectrogram -> SmoothSpectrogram
smoothen (BarkScaledSpectrogram s) =
	SmoothSpectrogram $ fmap (DSP.window (DSP.hanning 1024)) s
```

To evaluate loudness we just have to take each of the frequency bands and sum it all:

$$ L_{dB}(t) = \frac{\sum_{k=1}{N}E_k}{N} $$

where \\(E_k\\) represents the magnitude of the kth frequency band in the spectrogram.
There are \\(N\\) of them.

```haskell top
loudnessEvaluation :: SmoothSpectrogram -> EventDetectionFunction
loudnessEvaluation (SmoothSpectrogram s) =
	EventDetectionFunction $ result
  where
    freqBandSum k = (foldl (+) 0 k) / (fromIntegral $ length s)
    result = fmap freqBandSum s
```

## 3. Testing

We can now proceed to test everything with some sample. Let's add some utility functions
to load up a `wav` file:

```haskell top
readWavFile :: String -> IO [Double]
readWavFile fileName = do
	handle <- Snd.openFile fileName Snd.ReadMode Snd.defaultInfo
	(info, Just buf) <- Snd.hGetContents handle :: IO (Snd.Info, Maybe (BV.Buffer Double))
	return (toList $ BV.fromBuffer buf)
  where
  	toList = Vector.foldl (\a b -> a ++ [b]) []
```

Let's load our test file:

```haskell do
arrSnd <- readWavFile "resources/heartbeat.wav"
```

Now, let's try plotting the loudnessEvaluation function for it:

```haskell top
plotData :: SmoothSpectrogram -> Text
plotData (SmoothSpectrogram arr) = "Plotly.newPlot('div1'," <> data' <> ");"
  where
  	toList = foldl (\a b -> a ++ [b]) []
    data' = "[{z:"
    	 <> Text.pack (show (map toList arr))
         <> ",type: 'heatmap'"
         <> "}];"
```

```haskell eval
let BarkScaledSpectrogram p = FilteredSound arrSnd & makeSpectrogram & barkscale in script_ (plotData $ SmoothSpectrogram p) :: Html ()
```
