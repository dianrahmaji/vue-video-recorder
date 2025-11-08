<template>
  <div class="app">
    <h1>Video Recorder</h1>

    <section class="controls">
      <label>
        Quality / FPS
        <select v-model="selected" :disabled="isRecording">
          <option v-for="(opt, key) in options" :key="key" :value="key">
            {{ opt.label }}
          </option>
        </select>
      </label>

      <label>
        Timer (seconds)
        <input type="number" v-model.number="timerSeconds" min="1" :disabled="isRecording" />
      </label>

      <div class="buttons">
        <button @click="startRecording" :disabled="isRecording">Start</button>
        <button @click="stopRecording" :disabled="!isRecording">Stop</button>
      </div>

      <div class="status">
        <div v-if="isRecording">Recording — remaining: {{ remaining }}s</div>
        <div v-else-if="lastBlobUrl">Recorded — <a :href="lastBlobUrl" :download="lastFileName">Download</a></div>
        <div v-else>Idle</div>
      </div>
    </section>

    <section class="preview">
      <h2>Preview</h2>
      <video ref="previewEl" autoplay muted playsinline></video>

      <h2 v-if="lastBlobUrl">Playback</h2>
      <video v-if="lastBlobUrl" :src="lastBlobUrl" controls controlsList="nodownload"></video>
    </section>

    <p class="notes">
      Notes: uses MediaRecorder (webm). If browser supports showSaveFilePicker it will be used for saving; otherwise a download link is created.
    </p>
  </div>
</template>

<script setup lang="ts">
import { ref, onBeforeUnmount, watch } from 'vue'

type Option = {
  label: string
  constraints: MediaTrackConstraints
}

const options: Record<string, Option> = {
  '1280_30': { label: '1280x720 30fps (default)', constraints: { width: { ideal: 1280 }, height: { ideal: 720 }, frameRate: { ideal: 30 } } },
  '1280_24': { label: '1280x720 24fps', constraints: { width: { ideal: 1280 }, height: { ideal: 720 }, frameRate: { ideal: 24 } } },
  '640_30':  { label: '640x480 30fps',  constraints: { width: { ideal: 640 },  height: { ideal: 480 }, frameRate: { ideal: 30 } } },
  '640_24':  { label: '640x480 24fps',  constraints: { width: { ideal: 640 },  height: { ideal: 480 }, frameRate: { ideal: 24 } } },
}

const selected = ref<string>('1280_30')
const timerSeconds = ref<number>(60) // default 1 minute
const remaining = ref<number>(timerSeconds.value)
const isRecording = ref(false)
const previewEl = ref<HTMLVideoElement | null>(null)

let mediaStream: MediaStream | null = null
let recorder: MediaRecorder | null = null
let chunks: Blob[] = []
let countdownHandle: number | null = null

const lastBlobUrl = ref<string | null>(null)
// default target filename is .mp4
const lastFileName = ref<string>('recording.mp4')

watch(timerSeconds, (v) => {
  if (v < 1) timerSeconds.value = 1
  remaining.value = timerSeconds.value
})

function buildConstraints() {
  const video = options[selected.value]!.constraints
  return { audio: true, video }
}

async function startPreview() {
  try {
    const constraints = buildConstraints()
    mediaStream = await navigator.mediaDevices.getUserMedia(constraints as MediaStreamConstraints)
    if (previewEl.value) {
      previewEl.value.srcObject = mediaStream
      await previewEl.value.play().catch(() => {})
    }
  } catch (err) {
    console.error('getUserMedia error', err)
    stopAndCleanupStream()
    throw err
  }
}

function stopAndCleanupStream() {
  if (mediaStream) {
    mediaStream.getTracks().forEach((t) => t.stop())
    mediaStream = null
  }
  if (previewEl.value) previewEl.value.srcObject = null
}

function startCountdown() {
  remaining.value = timerSeconds.value
  countdownHandle = window.setInterval(() => {
    remaining.value -= 1
    if (remaining.value <= 0) {
      remaining.value = 0
      stopRecording()
    }
  }, 1000)
}

function stopCountdown() {
  if (countdownHandle != null) {
    clearInterval(countdownHandle)
    countdownHandle = null
  }
}

async function startRecording() {
  try {
    // clear previous
    if (lastBlobUrl.value) {
      URL.revokeObjectURL(lastBlobUrl.value)
      lastBlobUrl.value = null
    }

    await startPreview()
    if (!mediaStream) return

    chunks = []
    const mimeTypeCandidates = [
      // try mp4 first (some browsers / platforms support direct mp4 recording)
      'video/mp4;codecs=h264,aac',
      'video/mp4',
      'video/webm;codecs=vp9,opus',
      'video/webm;codecs=vp8,opus',
      'video/webm'
    ]
    let mimeType = ''
    for (const m of mimeTypeCandidates) {
      if (MediaRecorder.isTypeSupported && MediaRecorder.isTypeSupported(m)) {
        mimeType = m
        break
      }
    }

    recorder = new MediaRecorder(mediaStream, mimeType ? { mimeType } : undefined)
    recorder.ondataavailable = (ev) => {
      if (ev.data && ev.data.size > 0) chunks.push(ev.data)
    }

    recorder.onstop = async () => {
      try {
        const recordedBlob = new Blob(chunks, { type: mimeType || 'video/webm' })
        const timestamp = new Date().toISOString().replace(/[:.]/g, '-')
        const webmName = `recording-${timestamp}.webm`
        const mp4Name = `recording-${timestamp}.mp4`
        lastFileName.value = mp4Name

        // If MediaRecorder produced MP4 directly, save it as-is
        if ((recordedBlob.type && recordedBlob.type.includes('mp4')) || (mimeType && mimeType.startsWith('video/mp4'))) {
          // direct mp4 blob
          await saveBlob(recordedBlob, mp4Name)
          lastBlobUrl.value = URL.createObjectURL(recordedBlob)
          stopAndCleanupStream()
          return
        }


        // Fallback: save webm and offer download (browser will play webm)
        lastFileName.value = webmName
        await saveBlob(recordedBlob, webmName)
        lastBlobUrl.value = URL.createObjectURL(recordedBlob)
        stopAndCleanupStream()
      } catch (err) {
        console.error('onstop handler failed', err)
        stopAndCleanupStream()
      }
    }

    // helper: try showSaveFilePicker, otherwise trigger download link
    async function saveBlob(blob: Blob, name: string) {
      if ((window as any).showSaveFilePicker) {
        try {
          // @ts-ignore
          const handle = await (window as any).showSaveFilePicker({
            suggestedName: name,
            types: [{
              description: 'Video file',
              accept: { [blob.type || 'video/*']: [`.${name.split('.').pop()}`] }
            }]
          })
          const writable = await handle.createWritable()
          await writable.write(blob)
          await writable.close()
          return
        } catch (err) {
          console.warn('showSaveFilePicker failed, falling back to download', err)
        }
      }

      // fallback download link
      const url = URL.createObjectURL(blob)
      const a = document.createElement('a')
      a.style.display = 'none'
      a.href = url
      a.download = name
      document.body.appendChild(a)
      a.click()
      setTimeout(() => {
        document.body.removeChild(a)
        URL.revokeObjectURL(url)
      }, 1500)
    }

    recorder.start()
    isRecording.value = true
    startCountdown()
  } catch (err) {
    console.error('startRecording failed', err)
    stopAndCleanupStream()
    isRecording.value = false
  }
}

function stopRecording() {
  stopCountdown()
  if (recorder && recorder.state !== 'inactive') {
    recorder.stop()
  } else {
    // ensure stream cleaned
    stopAndCleanupStream()
  }
  isRecording.value = false
}

onBeforeUnmount(() => {
  stopCountdown()
  if (recorder && recorder.state !== 'inactive') recorder.stop()
  stopAndCleanupStream()
  if (lastBlobUrl.value) {
    URL.revokeObjectURL(lastBlobUrl.value)
  }
})
</script>

<style scoped>
.app {
  max-width: 900px;
  margin: 20px auto;
  font-family: system-ui, -apple-system, "Segoe UI", Roboto, "Helvetica Neue", Arial;
  padding: 1rem;
  border: 1px solid #eee;
  border-radius: 8px;
}
.controls {
  display: flex;
  gap: 1rem;
  align-items: center;
  flex-wrap: wrap;
}
.controls label {
  display: flex;
  flex-direction: column;
  font-size: 0.9rem;
}
.buttons {
  display: flex;
  gap: 0.5rem;
}
.preview video {
  width: 100%;
  max-width: 640px;
  border: 1px solid #ccc;
  margin-top: 0.5rem;
}
.status {
  margin-top: 0.5rem;
}
.notes {
  margin-top: 1rem;
  font-size: 0.85rem;
  color: #666;
}
</style>