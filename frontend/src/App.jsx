import { useState, useRef, useCallback, useEffect } from "react";
import {
  Upload,
  Mic,
  FileAudio,
  Loader2,
  Download,
  Copy,
  Check,
  Clock,
  AudioWaveform,
  X,
  Search,
  Play,
  Pause,
  Square,
  Sun,
  Moon,
  Keyboard,
  Edit3,
  SkipBack,
  SkipForward,
  Volume2,
  Languages,
} from "lucide-react";
import { jsPDF } from "jspdf";
import "./App.css";

const BATCH_API_URL = import.meta.env.VITE_API_URL || "https://6zycjezzgfcjine4fhvsceohz40hetxs.lambda-url.us-east-1.on.aws/";
let API_URL = BATCH_API_URL;

const SHORT_AUDIO_THRESHOLD = 50 * 1024 * 1024; // 50 MB (~10 min audio)

const NLLB_LANG_CODES = {
  fr: "fra_Latn",
  en: "eng_Latn",
  ar: "arb_Arab",
  es: "spa_Latn",
  pt: "por_Latn",
};

function formatTime(seconds) {
  const h = Math.floor(seconds / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  const s = Math.floor(seconds % 60);
  if (h > 0) return `${h}h ${m.toString().padStart(2, "0")}m ${s.toString().padStart(2, "0")}s`;
  return `${m}m ${s.toString().padStart(2, "0")}s`;
}

function formatTimestamp(seconds) {
  const h = Math.floor(seconds / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  const s = Math.floor(seconds % 60);
  if (h > 0) return `${h}:${m.toString().padStart(2, "0")}:${s.toString().padStart(2, "0")}`;
  return `${m}:${s.toString().padStart(2, "0")}`;
}

function formatSrtTime(seconds) {
  const h = Math.floor(seconds / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  const s = Math.floor(seconds % 60);
  const ms = Math.round((seconds % 1) * 1000);
  return `${h.toString().padStart(2, "0")}:${m.toString().padStart(2, "0")}:${s.toString().padStart(2, "0")},${ms.toString().padStart(3, "0")}`;
}

function formatVttTime(seconds) {
  const h = Math.floor(seconds / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  const s = Math.floor(seconds % 60);
  const ms = Math.round((seconds % 1) * 1000);
  return `${h.toString().padStart(2, "0")}:${m.toString().padStart(2, "0")}:${s.toString().padStart(2, "0")}.${ms.toString().padStart(3, "0")}`;
}

export default function App() {
  const [file, setFile] = useState(null);
  const [status, setStatus] = useState("idle");
  const [statusMessage, setStatusMessage] = useState("");
  const [progress, setProgress] = useState({ chunk: 0, total: 0 });
  const [transcription, setTranscription] = useState("");
  const [segments, setSegments] = useState([]);
  const [duration, setDuration] = useState(0);
  const [copied, setCopied] = useState(false);
  const [dragOver, setDragOver] = useState(false);
  const [searchQuery, setSearchQuery] = useState("");
  const [showSearch, setShowSearch] = useState(false);
  const [elapsedTime, setElapsedTime] = useState(0);
  const [showExportMenu, setShowExportMenu] = useState(false);
  const [darkMode, setDarkMode] = useState(true);
  const [editingIndex, setEditingIndex] = useState(null);
  const [editText, setEditText] = useState("");
  const [showShortcuts, setShowShortcuts] = useState(false);
  const [activeTab, setActiveTab] = useState("upload");
  const [isRecording, setIsRecording] = useState(false);
  const [recordingTime, setRecordingTime] = useState(0);
  const [audioUrl, setAudioUrl] = useState(null);
  const [isPlaying, setIsPlaying] = useState(false);
  const [playbackTime, setPlaybackTime] = useState(0);
  const [playbackSpeed, setPlaybackSpeed] = useState(1);
  const [activeSegmentIndex, setActiveSegmentIndex] = useState(-1);
  const [showTranslation, setShowTranslation] = useState(false);
  const [translatedText, setTranslatedText] = useState("");
  const [translationLang, setTranslationLang] = useState("fr");
  const [translating, setTranslating] = useState(false);

  const fileInputRef = useRef(null);
  const timerRef = useRef(null);
  const mediaRecorderRef = useRef(null);
  const audioChunksRef = useRef([]);
  const recordingTimerRef = useRef(null);
  const audioRef = useRef(null);
  const playbackTimerRef = useRef(null);

  useEffect(() => {
    document.documentElement.setAttribute("data-theme", darkMode ? "dark" : "light");
  }, [darkMode]);

  useEffect(() => {
    if (status === "processing") {
      timerRef.current = setInterval(() => {
        setElapsedTime((prev) => prev + 1);
      }, 1000);
    } else {
      clearInterval(timerRef.current);
      if (status === "idle") setElapsedTime(0);
    }
    return () => clearInterval(timerRef.current);
  }, [status]);

  useEffect(() => {
    const handleKeyDown = (e) => {
      if (e.ctrlKey && e.key === "f") {
        e.preventDefault();
        setShowSearch((prev) => !prev);
      }
      if (e.key === " " && e.target.tagName !== "INPUT" && e.target.tagName !== "TEXTAREA") {
        e.preventDefault();
        togglePlayback();
      }
      if (e.ctrlKey && e.key === "ArrowRight") {
        e.preventDefault();
        skipForward();
      }
      if (e.ctrlKey && e.key === "ArrowLeft") {
        e.preventDefault();
        skipBackward();
      }
    };
    window.addEventListener("keydown", handleKeyDown);
    return () => window.removeEventListener("keydown", handleKeyDown);
  }, [audioUrl, isPlaying]);

  const resetState = () => {
    setStatus("idle");
    setStatusMessage("");
    setProgress({ chunk: 0, total: 0 });
    setTranscription("");
    setSegments([]);
    setDuration(0);
    setElapsedTime(0);
    setActiveSegmentIndex(-1);
  };

  // ===== RECORDING =====
  const startRecording = async () => {
    try {
      const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
      const mediaRecorder = new MediaRecorder(stream);
      mediaRecorderRef.current = mediaRecorder;
      audioChunksRef.current = [];

      mediaRecorder.ondataavailable = (event) => {
        audioChunksRef.current.push(event.data);
      };

      mediaRecorder.onstop = () => {
        const audioBlob = new Blob(audioChunksRef.current, { type: "audio/webm" });
        const audioFile = new File([audioBlob], "enregistrement.webm", { type: "audio/webm" });
        setFile(audioFile);
        setAudioUrl(URL.createObjectURL(audioBlob));
        stream.getTracks().forEach((track) => track.stop());
      };

      mediaRecorder.start();
      setIsRecording(true);
      setRecordingTime(0);
      recordingTimerRef.current = setInterval(() => {
        setRecordingTime((prev) => prev + 1);
      }, 1000);
    } catch (err) {
      alert("Impossible d'accéder au microphone. Vérifiez les permissions.");
    }
  };

  const stopRecording = () => {
    if (mediaRecorderRef.current && isRecording) {
      mediaRecorderRef.current.stop();
      setIsRecording(false);
      clearInterval(recordingTimerRef.current);
    }
  };

  // ===== AUDIO PLAYER =====
  const togglePlayback = () => {
    if (!audioRef.current) return;
    if (isPlaying) {
      audioRef.current.pause();
      setIsPlaying(false);
    } else {
      audioRef.current.play();
      setIsPlaying(true);
    }
  };

  const skipForward = () => {
    if (audioRef.current) {
      audioRef.current.currentTime = Math.min(audioRef.current.currentTime + 5, audioRef.current.duration);
    }
  };

  const skipBackward = () => {
    if (audioRef.current) {
      audioRef.current.currentTime = Math.max(audioRef.current.currentTime - 5, 0);
    }
  };

  const changeSpeed = () => {
    const speeds = [0.5, 0.75, 1, 1.25, 1.5, 2];
    const currentIdx = speeds.indexOf(playbackSpeed);
    const nextIdx = (currentIdx + 1) % speeds.length;
    setPlaybackSpeed(speeds[nextIdx]);
    if (audioRef.current) audioRef.current.playbackRate = speeds[nextIdx];
  };

  const seekToSegment = (startTime) => {
    if (audioRef.current) {
      audioRef.current.currentTime = startTime;
      if (!isPlaying) {
        audioRef.current.play();
        setIsPlaying(true);
      }
    }
  };

  useEffect(() => {
    if (audioRef.current) {
      const updateTime = () => {
        setPlaybackTime(audioRef.current.currentTime);
        const currentTime = audioRef.current.currentTime;
        const idx = segments.findIndex(
          (seg) => currentTime >= seg.start && currentTime < seg.end
        );
        setActiveSegmentIndex(idx);
      };
      const handleEnded = () => setIsPlaying(false);
      audioRef.current.addEventListener("timeupdate", updateTime);
      audioRef.current.addEventListener("ended", handleEnded);
      return () => {
        if (audioRef.current) {
          audioRef.current.removeEventListener("timeupdate", updateTime);
          audioRef.current.removeEventListener("ended", handleEnded);
        }
      };
    }
  }, [segments, audioUrl]);

  // ===== FILE HANDLING =====
  const handleFile = (selectedFile) => {
    if (!selectedFile) return;
    const ext = selectedFile.name.split(".").pop().toLowerCase();
    const allowedExt = ["mp3", "wav", "m4a", "ogg", "flac", "webm", "mp4", "aac", "wma"];
    if (!allowedExt.includes(ext)) {
      alert("Format non supporté. Utilisez: MP3, WAV, M4A, OGG, FLAC, WebM, MP4, AAC, WMA");
      return;
    }
    resetState();
    setFile(selectedFile);
    setAudioUrl(URL.createObjectURL(selectedFile));
  };

  // ===== TRANSCRIPTION (HF Space for short, Kaggle for long) =====
  const pollingRef = useRef(null);
  const jobIdRef = useRef(null);

  const transcribeViaMiniServer = async (audioFile) => {
    // 1. Get presigned URL and upload to S3
    setStatusMessage("Upload...");
    const uploadRes = await fetch(API_URL + "upload", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ filename: audioFile.name, mode: "mini" }),
    });
    if (!uploadRes.ok) throw new Error("Erreur preparation upload");
    const { job_id, upload_url } = await uploadRes.json();
    jobIdRef.current = job_id;

    const uploadToS3 = await fetch(upload_url, {
      method: "PUT",
      headers: { "Content-Type": "audio/*" },
      body: audioFile,
    });
    if (!uploadToS3.ok) throw new Error("Echec upload");

    // 2. Tell Lambda to transcribe via mini-server
    setStatusMessage("Transcription instantanee...");
    const response = await fetch(API_URL + "transcribe-s3", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ job_id, audio_key: `uploads/${job_id}/audio.${audioFile.name.split('.').pop()}` }),
    });
    if (!response.ok) throw new Error("Erreur transcription");
    return await response.json();
  };

  const transcribeViaKaggle = async (audioFile) => {
    // 1. Get presigned upload URL
    setStatusMessage("Upload vers le serveur...");
    const uploadRes = await fetch(API_URL + "upload", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ filename: audioFile.name }),
    });
    if (!uploadRes.ok) throw new Error("Impossible de preparer l'upload");
    const { job_id, upload_url } = await uploadRes.json();
    jobIdRef.current = job_id;

    // 2. Upload file directly to S3
    const uploadToS3 = await fetch(upload_url, {
      method: "PUT",
      headers: { "Content-Type": "audio/*" },
      body: audioFile,
    });
    if (!uploadToS3.ok) throw new Error("Echec de l'upload");

    // 3. Poll for status
    setStatusMessage("Transcription Kaggle GPU en cours (5-10 min)...");
    return new Promise((resolve, reject) => {
      pollingRef.current = setInterval(async () => {
        try {
          const statusRes = await fetch(API_URL + "status/" + job_id);
          const statusData = await statusRes.json();

          if (statusData.status === "done") {
            clearInterval(pollingRef.current);
            pollingRef.current = null;
            const resultRes = await fetch(API_URL + "result/" + job_id);
            const result = await resultRes.json();
            resolve(result);
          } else if (statusData.status === "failed") {
            clearInterval(pollingRef.current);
            pollingRef.current = null;
            reject(new Error(statusData.error || "La transcription a echoue"));
          } else {
            setStatusMessage(`Transcription GPU en cours... (${statusData.status})`);
          }
        } catch (err) {
          clearInterval(pollingRef.current);
          pollingRef.current = null;
          reject(err);
        }
      }, 5000);
    });
  };

  const startTranscription = useCallback(async () => {
    if (!file) return;

    setStatus("processing");
    setStatusMessage("Preparation...");
    setTranscription("");
    setSegments([]);
    setProgress({ chunk: 0, total: 0 });

    try {
      const isShortAudio = file.size < SHORT_AUDIO_THRESHOLD;

      if (isShortAudio) {
        // Short audio → Mini-server (instant, ~5 sec)
        setStatusMessage("Transcription instantanee...");
        const result = await transcribeViaMiniServer(file);
        setTranscription(result.text || "");
        setSegments(result.segments || []);
        setDuration(result.duration || 0);
        setStatus("done");
        setStatusMessage(`Transcription terminee ! (${Math.round(result.processing_time || 0)}s)`);
      } else {
        // Long audio → Kaggle (supports 6h+)
        setStatusMessage("Audio long detecte — envoi vers Kaggle GPU...");
        const result = await transcribeViaKaggle(file);
        setTranscription(result.text || "");
        setSegments(result.segments || []);
        setDuration(result.duration || 0);
        if (result.translation) {
          setTranslatedText(result.translation);
          setShowTranslation(true);
        }
        setStatus("done");
        setStatusMessage(`Transcription terminee ! (${result.device || "kaggle-gpu"}, ${Math.round(result.processing_time || 0)}s)`);
      }
    } catch (err) {
      setStatus("error");
      setStatusMessage(`Erreur: ${err.message}`);
    }
  }, [file]);

  const cancelTranscription = () => {
    if (pollingRef.current) { clearInterval(pollingRef.current); pollingRef.current = null; }
    setStatus("idle");
    setStatusMessage("Annulé");
  };

  // ===== EDITING =====
  const startEdit = (index) => {
    setEditingIndex(index);
    setEditText(segments[index].text);
  };

  const saveEdit = () => {
    if (editingIndex !== null) {
      const updated = [...segments];
      updated[editingIndex] = { ...updated[editingIndex], text: editText };
      setSegments(updated);
      setTranscription(updated.map((s) => s.text).join(" "));
      setEditingIndex(null);
    }
  };

  const cancelEdit = () => {
    setEditingIndex(null);
    setEditText("");
  };

  // ===== TRANSLATION =====
  const translateText = async () => {
    if (!transcription) return;
    setTranslating(true);
    setShowTranslation(true);
    if (translationLang === "fr" && segments.length > 0 && segments[0].translation) {
      const fullTranslation = segments.map(s => s.translation).join(" ");
      setTranslatedText(fullTranslation);
      setTranslating(false);
      return;
    }
    setTranslatedText("[Traduction disponible uniquement en francais pour le moment]");
    setTranslating(false);
  };

  // ===== COPY & EXPORT =====
  const copyToClipboard = async () => {
    await navigator.clipboard.writeText(transcription);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  };

  const downloadTranscription = (format) => {
    const filename = file?.name?.replace(/\.[^.]+$/, "") || "wolof";

    if (format === "pdf") {
      const doc = new jsPDF();
      doc.setFont("helvetica", "bold");
      doc.setFontSize(16);
      doc.text("Transcription Wolof", 20, 20);
      doc.setFont("helvetica", "normal");
      doc.setFontSize(10);
      doc.text(`Fichier: ${file?.name || "audio"}`, 20, 30);
      doc.text(`Duree: ${formatTime(duration)}`, 20, 36);
      doc.text(`Mots: ${wordCount}`, 20, 42);
      doc.line(20, 46, 190, 46);
      let y = 54;
      doc.setFontSize(11);
      if (segments.length > 0) {
        segments.forEach((seg) => {
          if (y > 270) { doc.addPage(); y = 20; }
          doc.setFont("helvetica", "bold");
          doc.setFontSize(9);
          doc.setTextColor(108, 99, 255);
          doc.text(`[${formatTimestamp(seg.start)} - ${formatTimestamp(seg.end)}]`, 20, y);
          doc.setFont("helvetica", "normal");
          doc.setFontSize(11);
          doc.setTextColor(0, 0, 0);
          const lines = doc.splitTextToSize(seg.text, 160);
          doc.text(lines, 20, y + 5);
          y += 5 + lines.length * 5 + 4;
        });
      } else {
        const lines = doc.splitTextToSize(transcription, 170);
        doc.text(lines, 20, y);
      }
      doc.save(`${filename}.pdf`);
    } else if (format === "srt") {
      let content = "";
      segments.forEach((seg, i) => {
        content += `${i + 1}\n${formatSrtTime(seg.start)} --> ${formatSrtTime(seg.end)}\n${seg.text}\n\n`;
      });
      downloadFile(content, `${filename}.srt`, "text/srt");
    } else if (format === "vtt") {
      let content = "WEBVTT\n\n";
      segments.forEach((seg, i) => {
        content += `${i + 1}\n${formatVttTime(seg.start)} --> ${formatVttTime(seg.end)}\n${seg.text}\n\n`;
      });
      downloadFile(content, `${filename}.vtt`, "text/vtt");
    } else if (format === "json") {
      const data = { file: file?.name, duration, language: "wo", segments, text: transcription };
      downloadFile(JSON.stringify(data, null, 2), `${filename}.json`, "application/json");
    } else {
      let content = `Transcription Wolof\nFichier: ${file?.name || "audio"}\nDurée: ${formatTime(duration)}\n${"=".repeat(50)}\n\n`;
      if (segments.length > 0) {
        segments.forEach((seg) => {
          content += `[${formatTimestamp(seg.start)} → ${formatTimestamp(seg.end)}]\n${seg.text}\n\n`;
        });
      } else {
        content += transcription;
      }
      downloadFile(content, `${filename}.txt`, "text/plain");
    }
    setShowExportMenu(false);
  };

  const downloadFile = (content, filename, mimeType) => {
    const blob = new Blob([content], { type: `${mimeType};charset=utf-8` });
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = filename;
    a.click();
    URL.revokeObjectURL(url);
  };

  const handleDrop = (e) => {
    e.preventDefault();
    setDragOver(false);
    const droppedFile = e.dataTransfer.files[0];
    if (droppedFile) handleFile(droppedFile);
  };

  const filteredSegments = searchQuery
    ? segments.filter((seg) => seg.text.toLowerCase().includes(searchQuery.toLowerCase()))
    : segments;

  const wordCount = transcription.split(/\s+/).filter(Boolean).length;

  return (
    <div className={`app ${darkMode ? "dark" : "light"}`}>
      <header className="header">
        <div className="header-top">
          <div className="logo">
            <Mic className="logo-icon" />
            <h1>Wolof Transcriber</h1>
          </div>
          <div className="header-actions">
            <button className="btn-icon-sm" onClick={() => setShowShortcuts(!showShortcuts)} title="Raccourcis">
              <Keyboard size={18} />
            </button>
            <button className="btn-icon-sm" onClick={() => setDarkMode(!darkMode)} title="Thème">
              {darkMode ? <Sun size={18} /> : <Moon size={18} />}
            </button>
          </div>
        </div>
        <p className="subtitle">
          Transcription audio wolof avec IA — Whisper Large-V3 fine-tuné sur 281h
        </p>
        <div className="lang-badge">
          <span className="badge">Wolof</span>
          <span className="badge badge-model">Whisper Large-V3</span>
          <span className="badge badge-llm">Correction LLM</span>
        </div>
      </header>

      {showShortcuts && (
        <div className="shortcuts-panel">
          <h3>Raccourcis clavier</h3>
          <div className="shortcut-list">
            <div><kbd>Espace</kbd> Lecture/Pause</div>
            <div><kbd>Ctrl+F</kbd> Rechercher</div>
            <div><kbd>Ctrl+→</kbd> Avancer 5s</div>
            <div><kbd>Ctrl+←</kbd> Reculer 5s</div>
          </div>
          <button className="btn-close" onClick={() => setShowShortcuts(false)}><X size={16} /></button>
        </div>
      )}

      <main className="main">
        {/* Tab switcher */}
        <div className="tabs">
          <button className={`tab ${activeTab === "upload" ? "active" : ""}`} onClick={() => setActiveTab("upload")}>
            <Upload size={16} />
            Importer
          </button>
          <button className={`tab ${activeTab === "record" ? "active" : ""}`} onClick={() => setActiveTab("record")}>
            <Mic size={16} />
            Enregistrer
          </button>
        </div>

        {/* Upload Tab */}
        {activeTab === "upload" && (
          <div
            className={`upload-zone ${dragOver ? "drag-over" : ""} ${file ? "has-file" : ""}`}
            onDragOver={(e) => { e.preventDefault(); setDragOver(true); }}
            onDragLeave={() => setDragOver(false)}
            onDrop={handleDrop}
            onClick={() => status === "idle" && !file && fileInputRef.current?.click()}
          >
            <input
              ref={fileInputRef}
              type="file"
              accept="audio/*,video/mp4,video/webm"
              onChange={(e) => handleFile(e.target.files[0])}
              hidden
            />
            {!file ? (
              <div className="upload-content">
                <Upload className="upload-icon" />
                <h3>Déposez votre fichier audio ici</h3>
                <p>ou cliquez pour sélectionner</p>
                <span className="formats">MP3, WAV, M4A, OGG, FLAC, WebM, MP4, AAC — jusqu'à 6h+</span>
              </div>
            ) : (
              <div className="file-info">
                <FileAudio className="file-icon" />
                <div className="file-details">
                  <span className="file-name">{file.name}</span>
                  <span className="file-size">{(file.size / (1024 * 1024)).toFixed(1)} MB</span>
                </div>
                {status === "idle" && (
                  <button className="remove-file" onClick={(e) => { e.stopPropagation(); setFile(null); setAudioUrl(null); resetState(); }}>
                    <X size={18} />
                  </button>
                )}
              </div>
            )}
          </div>
        )}

        {/* Record Tab */}
        {activeTab === "record" && (
          <div className="record-zone">
            <div className={`record-visual ${isRecording ? "recording" : ""}`}>
              <Mic size={48} />
            </div>
            <p className="record-time">{formatTime(recordingTime)}</p>
            {!isRecording && !file ? (
              <button className="btn-record" onClick={startRecording}>
                <Mic size={20} />
                Commencer l'enregistrement
              </button>
            ) : isRecording ? (
              <button className="btn-stop" onClick={stopRecording}>
                <Square size={20} />
                Arrêter
              </button>
            ) : (
              <div className="record-done">
                <p className="file-name">enregistrement.webm</p>
                <button className="btn-reset" onClick={() => { setFile(null); setAudioUrl(null); resetState(); }}>
                  Recommencer
                </button>
              </div>
            )}
          </div>
        )}

        {/* Audio Player */}
        {audioUrl && (
          <div className="audio-player">
            <audio ref={audioRef} src={audioUrl} preload="metadata" />
            <div className="player-controls">
              <button className="player-btn" onClick={skipBackward} title="Reculer 5s">
                <SkipBack size={18} />
              </button>
              <button className="player-btn play-btn" onClick={togglePlayback}>
                {isPlaying ? <Pause size={22} /> : <Play size={22} />}
              </button>
              <button className="player-btn" onClick={skipForward} title="Avancer 5s">
                <SkipForward size={18} />
              </button>
              <span className="player-time">{formatTimestamp(playbackTime)}</span>
              <div className="player-progress" onClick={(e) => {
                if (audioRef.current) {
                  const rect = e.currentTarget.getBoundingClientRect();
                  const pct = (e.clientX - rect.left) / rect.width;
                  audioRef.current.currentTime = pct * audioRef.current.duration;
                }
              }}>
                <div className="player-progress-fill" style={{ width: audioRef.current ? `${(playbackTime / (audioRef.current.duration || 1)) * 100}%` : "0%" }} />
              </div>
              <button className="speed-btn" onClick={changeSpeed} title="Vitesse">
                {playbackSpeed}x
              </button>
            </div>
          </div>
        )}

        {/* Transcribe Button */}
        <div className="actions">
          {status === "idle" && file && (
            <button className="btn-primary" onClick={startTranscription}>
              <AudioWaveform size={20} />
              Transcrire en Wolof
            </button>
          )}
          {status === "processing" && (
            <button className="btn-cancel" onClick={cancelTranscription}>
              <X size={20} />
              Annuler
            </button>
          )}
        </div>

        {/* Progress */}
        {status === "processing" && (
          <div className="progress-section">
            <div className="progress-header">
              <Loader2 className="spinner" />
              <span>{statusMessage}</span>
            </div>
            {progress.total > 0 && (
              <div className="progress-bar-container">
                <div className="progress-bar" style={{ width: `${(progress.chunk / progress.total) * 100}%` }} />
                <span className="progress-text">{progress.chunk}/{progress.total} segments</span>
              </div>
            )}
            <div className="progress-meta">
              {duration > 0 && (
                <div className="duration-info"><Clock size={14} /><span>Durée: {formatTime(duration)}</span></div>
              )}
              <div className="duration-info"><Loader2 size={14} /><span>Écoulé: {formatTime(elapsedTime)}</span></div>
            </div>
          </div>
        )}

        {/* Results */}
        {(transcription || status === "done") && (
          <div className="result-section">
            <div className="result-header">
              <h2>Transcription</h2>
              <div className="result-actions">
                {segments.length > 0 && (
                  <button className="btn-icon" onClick={() => setShowSearch(!showSearch)} title="Rechercher (Ctrl+F)">
                    <Search size={18} />
                  </button>
                )}
                <button className="btn-icon" onClick={copyToClipboard} title="Copier">
                  {copied ? <Check size={18} /> : <Copy size={18} />}
                </button>
                <div className="export-wrapper">
                  <button className="btn-icon" onClick={() => setShowExportMenu(!showExportMenu)} title="Exporter">
                    <Download size={18} />
                  </button>
                  {showExportMenu && (
                    <div className="export-menu">
                      <button onClick={() => downloadTranscription("txt")}>Texte (.txt)</button>
                      <button onClick={() => downloadTranscription("pdf")}>PDF (.pdf)</button>
                      <button onClick={() => downloadTranscription("srt")}>Sous-titres (.srt)</button>
                      <button onClick={() => downloadTranscription("vtt")}>WebVTT (.vtt)</button>
                      <button onClick={() => downloadTranscription("json")}>JSON (.json)</button>
                    </div>
                  )}
                </div>
              </div>
            </div>

            {showSearch && (
              <div className="search-bar">
                <Search size={16} className="search-icon" />
                <input
                  type="text"
                  placeholder="Rechercher dans la transcription..."
                  value={searchQuery}
                  onChange={(e) => setSearchQuery(e.target.value)}
                  autoFocus
                />
                {searchQuery && (
                  <span className="search-count">
                    {filteredSegments.length} résultat{filteredSegments.length !== 1 ? "s" : ""}
                  </span>
                )}
                <button className="btn-close-sm" onClick={() => { setShowSearch(false); setSearchQuery(""); }}>
                  <X size={14} />
                </button>
              </div>
            )}

            {filteredSegments.length > 0 ? (
              <div className="segments">
                {filteredSegments.map((seg, i) => (
                  <div
                    key={i}
                    className={`segment ${activeSegmentIndex === i ? "active-segment" : ""}`}
                    onClick={() => seekToSegment(seg.start)}
                  >
                    <span className="timestamp">{formatTimestamp(seg.start)}</span>
                    {editingIndex === i ? (
                      <div className="edit-container">
                        <textarea
                          value={editText}
                          onChange={(e) => setEditText(e.target.value)}
                          className="edit-textarea"
                          autoFocus
                        />
                        <div className="edit-actions">
                          <button className="btn-save" onClick={saveEdit}>Sauver</button>
                          <button className="btn-cancel-sm" onClick={cancelEdit}>Annuler</button>
                        </div>
                      </div>
                    ) : (
                      <p className="segment-text">{seg.text}</p>
                    )}
                    {editingIndex !== i && (
                      <button className="btn-edit" onClick={(e) => { e.stopPropagation(); startEdit(i); }} title="Modifier">
                        <Edit3 size={14} />
                      </button>
                    )}
                  </div>
                ))}
              </div>
            ) : segments.length === 0 && transcription ? (
              <div className="full-text"><p>{transcription}</p></div>
            ) : searchQuery ? (
              <div className="no-results"><p>Aucun résultat pour "{searchQuery}"</p></div>
            ) : null}

            {status === "done" && (
              <div className="result-footer">
                <div className="result-stats">
                  <span>{formatTime(duration)} transcrits</span>
                  <span className="stat-divider">|</span>
                  <span>{wordCount} mots</span>
                  <span className="stat-divider">|</span>
                  <span>{segments.length} segments</span>
                </div>
              </div>
            )}

            {/* Translation Section - Auto-displayed */}
            {status === "done" && transcription && (
              <div className="translation-section">
                <div className="translation-header">
                  <h3><Languages size={18} /> Traduction en Francais</h3>
                  <div className="translation-controls">
                    <select
                      value={translationLang}
                      onChange={(e) => { setTranslationLang(e.target.value); setTranslatedText(""); }}
                      className="lang-select"
                    >
                      <option value="fr">Francais</option>
                      <option value="en">English</option>
                      <option value="ar">Arabe</option>
                      <option value="es">Espanol</option>
                      <option value="pt">Portugais</option>
                    </select>
                    <button className="btn-icon" onClick={async () => {
                      await navigator.clipboard.writeText(translatedText);
                    }} title="Copier la traduction" disabled={!translatedText}>
                      <Copy size={16} />
                    </button>
                  </div>
                </div>
                <div className="translation-result">
                  {translating ? (
                    <div className="translation-loading">
                      <Loader2 className="spinner" size={20} />
                      <span>Traduction en cours...</span>
                    </div>
                  ) : translatedText ? (
                    <div className="translation-text">
                      <p>{translatedText}</p>
                    </div>
                  ) : (
                    <div className="translation-loading">
                      <span>En attente de traduction...</span>
                    </div>
                  )}
                </div>
              </div>
            )}
          </div>
        )}

        {status === "error" && (
          <div className="error-section">
            <p>{statusMessage}</p>
            <button className="btn-primary" onClick={() => { resetState(); setFile(null); setAudioUrl(null); }}>
              Réessayer
            </button>
          </div>
        )}
      </main>

      <footer className="footer">
        <p>Wolof Transcriber — Whisper Large-V3 fine-tuné sur 281h | GPU acceleré | Traduction NLLB</p>
      </footer>
    </div>
  );
}
