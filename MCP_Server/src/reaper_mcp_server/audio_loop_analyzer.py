"""
音频循环点分析器 - 纯 Python 实现
用于绕过 REAPER GetAudioAccessorSamples API 的 bug
"""
import wave
import struct
import numpy as np
from pathlib import Path
from typing import List, Tuple, Optional


class LoopPointAnalyzer:
    """分析音频文件找到最佳循环点"""
    
    def __init__(self, file_path: str):
        self.file_path = Path(file_path)
        self.sample_rate = 0
        self.num_channels = 0
        self.samples = np.array([])
        
    def load_audio(self, section_start: float = 0, section_length: float = 0) -> bool:
        """加载音频文件（支持 WAV 格式）
        
        Args:
            section_start: 要加载的段落在文件中的起始时间（秒）
            section_length: 要加载的段落长度（秒），0表示加载全部
        """
        # 优先尝试 soundfile（支持 WAVE_FORMAT_EXTENSIBLE、24bit、float 等）
        try:
            import soundfile as sf
            data, sr = sf.read(str(self.file_path), dtype='float32')
            self.sample_rate = sr
            if data.ndim == 1:
                self.num_channels = 1
                self.samples = data
            else:
                self.num_channels = data.shape[1]
                self.samples = data[:, 0]  # 取左声道
            
            # 如果只需要段落，裁剪
            if section_start > 0 or section_length > 0:
                start_sample = int(section_start * sr)
                if section_length > 0:
                    end_sample = start_sample + int(section_length * sr)
                    self.samples = self.samples[start_sample:end_sample]
                else:
                    self.samples = self.samples[start_sample:]
            
            print(f"[LoopAnalyzer] soundfile 加载成功: {len(self.samples)} samples @ {sr}Hz")
            return True
        except ImportError:
            pass  # soundfile 未安装，继续回退
        except Exception as e:
            print(f"[LoopAnalyzer] soundfile 加载失败: {e}，尝试 wave 模块")
        
        # 回退到标准 wave 模块
        try:
            with wave.open(str(self.file_path), 'rb') as wf:
                self.num_channels = wf.getnchannels()
                self.sample_rate = wf.getframerate()
                num_frames = wf.getnframes()
                total_duration = num_frames / self.sample_rate
                
                # 计算要读取的帧范围
                start_frame = int(section_start * self.sample_rate)
                
                if section_length > 0:
                    # 只加载指定段落
                    frames_to_read = int(section_length * self.sample_rate)
                    print(f"[LoopAnalyzer] 加载段落: {section_start}s ~ {section_start + section_length}s (共 {section_length}s)")
                else:
                    # 加载从起始位置到结束
                    frames_to_read = num_frames - start_frame
                    print(f"[LoopAnalyzer] 加载从 {section_start}s 到文件结束 (共 {frames_to_read / self.sample_rate:.1f}s)")
                
                # 跳转到起始位置
                if start_frame > 0:
                    wf.setpos(start_frame)
                
                # 读取指定帧数
                raw_data = wf.readframes(frames_to_read)
                sample_width = wf.getsampwidth()
                
                # 根据采样宽度解析数据
                actual_samples = frames_to_read * self.num_channels
                if sample_width == 1:
                    fmt = f"{actual_samples}B"
                    samples = struct.unpack(fmt, raw_data)
                    samples = np.array(samples, dtype=np.float32) / 128.0 - 1.0
                elif sample_width == 2:
                    fmt = f"{actual_samples}h"
                    samples = struct.unpack(fmt, raw_data)
                    samples = np.array(samples, dtype=np.float32) / 32768.0
                elif sample_width == 3:
                    samples = self._parse_24bit(raw_data, actual_samples)
                elif sample_width == 4:
                    fmt = f"{actual_samples}i"
                    samples = struct.unpack(fmt, raw_data)
                    samples = np.array(samples, dtype=np.float32) / 2147483648.0
                else:
                    print(f"Unsupported sample width: {sample_width}")
                    return False
                
                # 如果是立体声，只取左声道
                if self.num_channels > 1:
                    self.samples = samples[::self.num_channels]
                else:
                    self.samples = samples
                    
                return True
                
        except Exception as e:
            print(f"Error loading audio: {e}")
            # 尝试用 pydub 作为备选
            return self._load_with_pydub()
    
    def _parse_24bit(self, raw_data: bytes, num_samples: int) -> np.ndarray:
        """解析 24-bit 音频数据"""
        samples = np.zeros(num_samples, dtype=np.float32)
        for i in range(num_samples):
            offset = i * 3
            if offset + 2 < len(raw_data):
                # 小端序 24-bit 转 32-bit
                sample = raw_data[offset] | (raw_data[offset + 1] << 8) | (raw_data[offset + 2] << 16)
                # 符号扩展
                if sample & 0x800000:
                    sample -= 0x1000000
                samples[i] = sample / 8388608.0
        return samples
    
    def _load_with_pydub(self) -> bool:
        """使用 pydub 作为备选加载方式"""
        try:
            from pydub import AudioSegment
            audio = AudioSegment.from_file(str(self.file_path))
            self.sample_rate = audio.frame_rate
            self.num_channels = audio.channels
            
            # 转换为 numpy 数组
            samples = np.array(audio.get_array_of_samples(), dtype=np.float32)
            
            # 根据采样宽度归一化
            if audio.sample_width == 1:
                samples = samples / 128.0 - 1.0
            elif audio.sample_width == 2:
                samples = samples / 32768.0
            elif audio.sample_width == 4:
                samples = samples / 2147483648.0
            
            # 如果是立体声，只取左声道
            if self.num_channels > 1:
                self.samples = samples[::self.num_channels]
            else:
                self.samples = samples
                
            return True
        except ImportError:
            print("pydub not available, cannot load non-standard WAV")
            return False
        except Exception as e:
            print(f"Error loading with pydub: {e}")
            return False
    
    def find_zero_crossings(self) -> List[int]:
        """查找所有零交叉点（采样点索引）"""
        if len(self.samples) == 0:
            return []
        
        zero_crossings = []
        for i in range(1, len(self.samples)):
            # 检测符号变化（包括从负到正和从正到负）
            if (self.samples[i-1] < 0 and self.samples[i] >= 0) or \
               (self.samples[i-1] >= 0 and self.samples[i] < 0):
                zero_crossings.append(i)
        
        return zero_crossings
    
    def calculate_correlation(self, seg1: np.ndarray, seg2: np.ndarray) -> float:
        """计算两个音频段的归一化互相关系数"""
        if len(seg1) != len(seg2) or len(seg1) == 0:
            return 0.0
        
        # 去均值
        mean1 = np.mean(seg1)
        mean2 = np.mean(seg2)
        seg1_centered = seg1 - mean1
        seg2_centered = seg2 - mean2
        
        # 计算相关系数
        numerator = np.sum(seg1_centered * seg2_centered)
        denominator = np.sqrt(np.sum(seg1_centered ** 2) * np.sum(seg2_centered ** 2))
        
        if denominator == 0:
            return 0.0
        
        return numerator / denominator
    
    def find_best_loop_region(self, min_loop_duration: float = 0.5, max_loop_duration: float = 10.0) -> Tuple[int, int, float]:
        """
        查找最佳循环区间（返回一个可以无缝循环的片段）
        
        Args:
            min_loop_duration: 最小循环长度（秒）
            max_loop_duration: 最大循环长度（秒）
            
        Returns:
            (start_sample, end_sample, correlation_score)
        """
        import time
        start_time = time.time()
        
        if len(self.samples) == 0:
            return 0, 0, 0.0
        
        # 转换为采样点数
        min_samples = int(min_loop_duration * self.sample_rate)
        max_samples = int(max_loop_duration * self.sample_rate)
        total_samples = len(self.samples)
        
        # 确保参数合理
        min_samples = max(min_samples, 100)
        max_samples = min(max_samples, total_samples // 2)
        
        print(f"[LoopAnalyzer] 搜索参数: total_samples={total_samples}, min_samples={min_samples}, max_samples={max_samples}")
        
        if min_samples >= total_samples:
            print(f"[LoopAnalyzer] 音频太短，无法搜索循环")
            return 0, total_samples - 1, 0.0
        
        # 查找零交叉点
        zero_crossings = self.find_zero_crossings()
        
        best_start = 0
        best_end = total_samples - 1
        best_score = -float('inf')
        
        # 优化：使用更大的步进，减少计算量
        step = max(1, int(self.sample_rate * 0.5))  # 500ms 步进（原来是100ms）
        duration_step = max(1, int(self.sample_rate * 1.0))  # 1秒长度步进
        
        # 限制最大搜索时间（秒）
        max_search_time = 5.0
        iterations = 0
        
        # 尝试不同的循环长度，找最佳匹配
        for loop_duration_samples in range(max_samples, min_samples - 1, -duration_step):
            # 检查是否超时
            if time.time() - start_time > max_search_time:
                print(f"[LoopAnalyzer] 搜索超时，已迭代 {iterations} 次，返回当前最佳结果")
                break
            
            # 在音频中滑动窗口，找最佳起始点
            for start in range(0, total_samples - loop_duration_samples - min_samples, step):
                iterations += 1
                end = start + loop_duration_samples
                
                # 比较循环点前后的波形（接尾和开头是否匹配）
                compare_len = min(int(0.05 * self.sample_rate), loop_duration_samples // 8)  # 50ms 对比窗口
                
                if end + compare_len > total_samples:
                    continue
                    
                # 循环结束前的片段 vs 循环开始后的片段
                end_segment = self.samples[end - compare_len:end]
                start_segment = self.samples[start:start + compare_len]
                
                score = self.calculate_correlation(end_segment, start_segment)
                
                if score > best_score:
                    best_score = score
                    best_start = start
                    best_end = end
                    
                # 如果找到很好的匹配，提前退出
                if best_score > 0.95:
                    print(f"[LoopAnalyzer] 找到优秀匹配 (score={best_score:.3f})，提前退出")
                    return best_start, best_end, best_score
        
        # 如果没找到好的，退而求其次：找零交叉点附近的区间
        if best_score < 0.3 and len(zero_crossings) > 1:
            for i in range(min(100, len(zero_crossings) - 1)):  # 限制最多检查100个零交叉点
                zc1 = zero_crossings[i]
                zc2 = zero_crossings[i + 1]
                duration = zc2 - zc1
                
                if min_samples <= duration <= max_samples:
                    compare_len = min(int(0.05 * self.sample_rate), duration // 8)
                    if zc2 + compare_len <= total_samples:
                        end_seg = self.samples[zc2 - compare_len:zc2]
                        start_seg = self.samples[zc1:zc1 + compare_len]
                        score = self.calculate_correlation(end_seg, start_seg)
                        
                        if score > best_score:
                            best_score = score
                            best_start = zc1
                            best_end = zc2
        
        elapsed = time.time() - start_time
        print(f"[LoopAnalyzer] 搜索完成，耗时 {elapsed:.2f}s，迭代 {iterations} 次，最佳分数: {best_score:.3f}")
        
        return best_start, best_end, best_score
    
    def analyze(self, min_loop_duration: float = 0.5, max_loop_duration: float = 10.0, section_start: float = 0, section_length: float = 0) -> dict:
        """执行完整分析并返回结果
        
        Args:
            min_loop_duration: 最小循环长度（秒）
            max_loop_duration: 最大循环长度（秒）
            section_start: 段落在文件中的起始时间（秒）
            section_length: 段落长度（秒）
        """
        if not self.load_audio(section_start, section_length):
            return {
                "success": False,
                "error": "无法加载音频文件"
            }
        
        zero_crossings = self.find_zero_crossings()
        start_sample, end_sample, score = self.find_best_loop_region(min_loop_duration, max_loop_duration)
        
        # 转换为时间
        start_time = start_sample / self.sample_rate
        end_time = end_sample / self.sample_rate
        loop_duration = end_time - start_time
        total_duration = len(self.samples) / self.sample_rate
        
        return {
            "success": True,
            "file": str(self.file_path),
            "sample_rate": int(self.sample_rate),
            "num_channels": int(self.num_channels),
            "total_samples": int(len(self.samples)),
            "duration": float(total_duration),
            "zero_crossings_count": int(len(zero_crossings)),
            "loop_start_sample": int(start_sample),
            "loop_end_sample": int(end_sample),
            "loop_start_time": float(start_time),
            "loop_end_time": float(end_time),
            "loop_duration": float(loop_duration),
            "correlation_score": float(score),
            "quality": "excellent" if score > 0.9 else "good" if score > 0.7 else "fair" if score > 0.5 else "poor"
        }


def analyze_file(file_path: str) -> dict:
    """便捷函数：分析单个文件"""
    analyzer = LoopPointAnalyzer(file_path)
    return analyzer.analyze()


if __name__ == "__main__":
    # 测试
    import sys
    if len(sys.argv) > 1:
        result = analyze_file(sys.argv[1])
        import json
        print(json.dumps(result, indent=2))
    else:
        print("Usage: python audio_loop_analyzer.py <audio_file>")
