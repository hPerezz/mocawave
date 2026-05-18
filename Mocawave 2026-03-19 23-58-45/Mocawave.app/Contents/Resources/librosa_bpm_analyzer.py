import sys
import librosa
import numpy as np


def get_bpm(audio_path):
    try:
        y, sr = librosa.load(audio_path, sr=None)
        # Try using tempo estimation instead of beat_track
        # This uses autocorrelation which is more robust
        tempo = librosa.beat.tempo(y=y, sr=sr)
        return float(tempo[0])
    except Exception as e:
        # Fallback: use onset detection and estimate tempo manually
        try:
            y, sr = librosa.load(audio_path, sr=None)
            onset_frames = librosa.onset.onset_detect(y=y, sr=sr)
            if len(onset_frames) > 1:
                # Calculate average time between onsets
                onset_times = librosa.frames_to_time(onset_frames, sr=sr)
                intervals = np.diff(onset_times)
                # Filter out outliers (keep intervals within reasonable BPM range)
                valid_intervals = intervals[(intervals > 0.3) & (intervals < 2.0)]
                if len(valid_intervals) > 0:
                    avg_interval = np.median(valid_intervals)
                    tempo = 60.0 / avg_interval
                    return float(tempo)
            # Last resort: use a simple tempo estimation
            tempo = librosa.beat.tempo(y=y, sr=sr, aggregate=np.median)
            return float(tempo[0])
        except Exception as e2:
            print(f"Error: {e2}", file=sys.stderr)
            return None


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Uso: python bpm.py /caminho/para/musica.mp3", file=sys.stderr)
        sys.exit(1)

    audio_path = sys.argv[1]
    bpm = get_bpm(audio_path)
    if bpm is not None:
        print(f"BPM estimado: {bpm:.2f}")
    else:
        print("Erro ao estimar BPM", file=sys.stderr)
        sys.exit(1)

