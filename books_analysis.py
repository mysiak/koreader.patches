#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
================================================================================
EPUB Page Count Heuristic Analyzer - Comprehensive Edition with Visualizations
================================================================================

PURPOSE:
This script analyzes your EPUB library to determine optimal page count 
estimation parameters for KOReader patches. It examines:

1. Characters per page standards (1800, 2200, 2500)
2. KB/page ratios for each standard
3. ZIP compression ratios to detect HTML bloat
4. Correlation between compression and estimation error

METHODOLOGY:

Step 1: Extract Ground Truth
- Opens each EPUB as a ZIP archive
- Finds all HTML/XHTML files (actual book content)
- Strips HTML tags to get pure text
- Counts characters and calculates "real" page count based on chars/page

Step 2: Analyze File Characteristics
- Records uncompressed HTML size (content KB)
- Records compressed HTML size (from ZIP headers)
- Calculates compression ratio = uncompressed / compressed
- Higher ratio = more repetitive markup = "bloated" HTML

Step 3: Test Static Ratios
- For each chars/page standard, tests multiple KB/page divisors
- Calculates error statistics (mean, median, percentiles)
- Identifies optimal static ratio for each standard

Step 4: Compression-Aware Analysis
- Groups books by compression ratio (low/mid/high)
- Checks if high-compression books have higher errors
- Tests dynamic correction formulas

Step 5: Recommendations
- Provides optimal static ratios
- Suggests compression-aware adjustments
- Shows expected accuracy improvements

Step 6: Generate Visualizations (OPTIONAL)
- Error distribution histograms
- Compression ratio scatter plots
- Accuracy comparison charts
- Percentile performance graphs

================================================================================
HEURISTIC ALGORITHM EXPLANATION
================================================================================

The core estimation formula is:
    estimated_pages = html_content_kb / kb_per_page_divisor

Traditional approach uses fixed divisor (e.g., 2.7 KB/page).

Problem: Books vary in HTML verbosity:
- Clean EPUBs: ~2.5 KB/page (minimal markup)
- Normal EPUBs: ~2.7-3.0 KB/page (standard formatting)
- Bloated EPUBs: ~4-8 KB/page (excessive <span> tags, inline styles)

Compression-Aware Enhancement:
    compression_ratio = uncompressed_size / compressed_size
    
    if compression_ratio > 3.5:
        # High compression = lots of repetitive markup
        bloat_adjustment = (compression_ratio - 3.0) * factor
        kb_per_page_divisor += bloat_adjustment
    
This dynamically increases the divisor for markup-heavy books, reducing
over-estimation WITHOUT slowing down the reader (compression data is already
in the ZIP headers we read anyway).

================================================================================
USAGE
================================================================================

    python script.py [directory]                    # Text output only
    python script.py [directory] --charts           # Generate charts
    
NOTES:
    - Charts are saved to ./epub_analysis_charts/ relative to script location
    - Book directory is only read, never modified

================================================================================
"""


import os
import sys
import zipfile
from pathlib import Path
import re
from collections import defaultdict
import argparse

# Try to import plotting libraries (optional)
PLOTTING_AVAILABLE = False
try:
    import matplotlib
    matplotlib.use('Agg')
    import matplotlib.pyplot as plt
    import matplotlib.patches as mpatches
    import numpy as np
    import seaborn as sns
    
    sns.set_style("whitegrid")
    plt.rcParams['figure.figsize'] = (12, 8)
    plt.rcParams['font.size'] = 10
    
    PLOTTING_AVAILABLE = True
except ImportError as e:
    PLOTTING_MISSING_REASON = str(e)

def safe_print(text):
    """Print with fallback for encoding issues"""
    try:
        print(text)
    except UnicodeEncodeError:
        print(text.encode('ascii', errors='replace').decode('ascii'))

def get_script_directory():
    """Get the directory where this script is located"""
    return Path(__file__).parent.resolve()

def analyze_epub(epub_path, chars_per_page):
    """
    Analyzes a single EPUB file.
    
    Returns dict with:
    - real_pages: Ground truth page count
    - content_kb_uncompressed: Total HTML size
    - content_kb_compressed: Compressed HTML size
    - compression_ratio: Uncompressed / Compressed
    - filename: Book filename
    """
    try:
        with zipfile.ZipFile(epub_path, 'r') as zf:
            total_html_uncompressed = 0
            total_html_compressed = 0
            total_chars = 0
            html_count = 0
            
            for info in zf.infolist():
                if re.search(r'\.x?html?$', info.filename, re.IGNORECASE):
                    total_html_uncompressed += info.file_size
                    total_html_compressed += info.compress_size
                    html_count += 1

            if total_html_uncompressed < 5000: 
                return None

            for info in zf.infolist():
                if re.search(r'\.x?html?$', info.filename, re.IGNORECASE):
                    try:
                        content = zf.read(info.filename).decode('utf-8', errors='ignore')
                        text = re.sub(r'<[^>]+>', '', content)
                        chars = len(re.sub(r'\s+', ' ', text).strip())
                        total_chars += chars
                    except:
                        pass
            
            if total_chars == 0 or html_count == 0:
                return None
            
            real_pages = total_chars / chars_per_page
            content_kb_uncompressed = total_html_uncompressed / 1024.0
            content_kb_compressed = total_html_compressed / 1024.0
            compression_ratio = content_kb_uncompressed / content_kb_compressed if content_kb_compressed > 0 else 0
            
            return {
                'filename': Path(epub_path).name,
                'real_pages': real_pages,
                'content_kb_uncompressed': content_kb_uncompressed,
                'content_kb_compressed': content_kb_compressed,
                'compression_ratio': compression_ratio,
                'total_chars': total_chars,
                'html_files': html_count
            }
    except Exception as e:
        return None

def calculate_error_stats(results, kb_divisor):
    """Calculate error statistics for a given KB/page divisor"""
    errors = []
    abs_errors = []
    
    for r in results:
        estimated = r['content_kb_uncompressed'] / kb_divisor
        error = ((estimated - r['real_pages']) / r['real_pages']) * 100
        errors.append(error)
        abs_errors.append(abs(error))
    
    if not abs_errors:
        return None
    
    sorted_abs = sorted(abs_errors)
    n = len(sorted_abs)
    
    return {
        'mean_abs_error': sum(abs_errors) / n,
        'median_abs_error': sorted_abs[n // 2],
        'p75_abs_error': sorted_abs[int(n * 0.75)],
        'p90_abs_error': sorted_abs[int(n * 0.90)],
        'max_abs_error': sorted_abs[-1],
        'under_10pct': sum(1 for e in abs_errors if e < 10) / n * 100,
        'under_15pct': sum(1 for e in abs_errors if e < 15) / n * 100,
        'under_20pct': sum(1 for e in abs_errors if e < 20) / n * 100,
        'mean_error': sum(errors) / n,
        'all_errors': abs_errors,
        'signed_errors': errors,
    }

def find_optimal_ratio(results, test_ratios):
    """Find optimal KB/page ratio by testing multiple values"""
    best_by_median = None
    best_median = float('inf')
    ratio_stats = {}
    
    for ratio in test_ratios:
        stats = calculate_error_stats(results, ratio)
        if stats:
            ratio_stats[ratio] = stats
            if stats['median_abs_error'] < best_median:
                best_median = stats['median_abs_error']
                best_by_median = ratio
    
    return best_by_median, ratio_stats

def analyze_compression_correlation(results, base_divisor):
    """Analyze correlation between compression ratio and estimation error"""
    low_comp = [r for r in results if r['compression_ratio'] < 3.0]
    mid_comp = [r for r in results if 3.0 <= r['compression_ratio'] < 4.0]
    high_comp = [r for r in results if r['compression_ratio'] >= 4.0]
    
    groups = {
        'low (<3.0)': low_comp,
        'mid (3.0-4.0)': mid_comp,
        'high (>=4.0)': high_comp
    }
    
    results_by_group = {}
    for name, group in groups.items():
        if group:
            stats = calculate_error_stats(group, base_divisor)
            results_by_group[name] = {
                'count': len(group),
                'stats': stats,
                'avg_ratio': sum(r['compression_ratio'] for r in group) / len(group)
            }
    
    return results_by_group

def test_compression_adjustment(results, base_divisor, adjustment_factors):
    """Test compression adjustment formulas with per-group analysis"""
    best_factor = None
    best_improvement = 0
    
    baseline_stats = calculate_error_stats(results, base_divisor)
    baseline_error = baseline_stats['median_abs_error']
    
    low_comp = [r for r in results if r['compression_ratio'] < 3.0]
    mid_comp = [r for r in results if 3.0 <= r['compression_ratio'] < 4.0]
    high_comp = [r for r in results if r['compression_ratio'] >= 4.0]
    
    baseline_groups = {}
    for name, group in [('low', low_comp), ('mid', mid_comp), ('high', high_comp)]:
        if group:
            baseline_groups[name] = calculate_error_stats(group, base_divisor)
    
    results_dict = {}
    
    for factor in adjustment_factors:
        adjusted_errors = []
        adjusted_errors_by_group = {'low': [], 'mid': [], 'high': []}
        
        for r in results:
            divisor = base_divisor
            if r['compression_ratio'] > 3.5:
                bloat = (r['compression_ratio'] - 3.0) * factor
                divisor = base_divisor + bloat
            
            estimated = r['content_kb_uncompressed'] / divisor
            error = abs((estimated - r['real_pages']) / r['real_pages']) * 100
            adjusted_errors.append(error)
            
            if r['compression_ratio'] < 3.0:
                adjusted_errors_by_group['low'].append(error)
            elif r['compression_ratio'] < 4.0:
                adjusted_errors_by_group['mid'].append(error)
            else:
                adjusted_errors_by_group['high'].append(error)
        
        if adjusted_errors:
            sorted_errors = sorted(adjusted_errors)
            median_error = sorted_errors[len(sorted_errors) // 2]
            improvement = baseline_error - median_error
            
            group_improvements = {}
            for group_name, errors in adjusted_errors_by_group.items():
                if errors and group_name in baseline_groups:
                    sorted_group = sorted(errors)
                    group_median = sorted_group[len(sorted_group) // 2]
                    baseline_group_median = baseline_groups[group_name]['median_abs_error']
                    group_improvement = baseline_group_median - group_median
                    group_improvements[group_name] = {
                        'before': baseline_group_median,
                        'after': group_median,
                        'improvement': group_improvement,
                        'improvement_pct': (group_improvement / baseline_group_median * 100) if baseline_group_median > 0 else 0
                    }
            
            results_dict[factor] = {
                'median_error': median_error,
                'improvement': improvement,
                'improvement_pct': (improvement / baseline_error) * 100,
                'all_errors': adjusted_errors,
                'group_improvements': group_improvements
            }
            
            if improvement > best_improvement:
                best_improvement = improvement
                best_factor = factor
    
    return best_factor, results_dict

def create_visualizations(all_results, standards, recommendations):
    """Generate visualization charts in script directory"""
    
    if not PLOTTING_AVAILABLE:
        safe_print("\nChart generation skipped: plotting libraries not available")
        safe_print(f"Reason: {PLOTTING_MISSING_REASON}")
        safe_print("Install with: pip install matplotlib seaborn numpy")
        return False
    
    script_dir = get_script_directory()
    output_dir = script_dir / "epub_analysis_charts"
    output_dir.mkdir(exist_ok=True)
    
    safe_print(f"\nGenerating visualizations: {output_dir.absolute()}")
    
    try:
        # Chart 1: Error Distribution Histograms
        fig, axes = plt.subplots(1, 3, figsize=(16, 5))
        fig.suptitle('Page Count Estimation Error Distribution by Standard', fontsize=14, fontweight='bold')
        
        for idx, (std_name, results) in enumerate(all_results.items()):
            optimal_ratio = recommendations[std_name]['optimal_ratio']
            stats = calculate_error_stats(results, optimal_ratio)
            errors = stats['all_errors']
            
            filtered_errors = [e for e in errors if e < 50]
            
            ax = axes[idx]
            ax.hist(filtered_errors, bins=50, color='steelblue', alpha=0.7, edgecolor='black')
            ax.axvline(stats['median_abs_error'], color='red', linestyle='--', linewidth=2, label=f'Median: {stats["median_abs_error"]:.1f}%')
            ax.axvline(10, color='green', linestyle=':', linewidth=1.5, label='±10% target')
            
            ax.set_xlabel('Absolute Error (%)')
            ax.set_ylabel('Number of Books')
            ax.set_title(f'{std_name} chars/page\n{optimal_ratio} KB/page ratio')
            ax.legend()
            ax.grid(True, alpha=0.3)
        
        plt.tight_layout()
        plt.savefig(output_dir / '01_error_distribution.png', dpi=150, bbox_inches='tight')
        safe_print("  Created: 01_error_distribution.png")
        plt.close()
        
        # Chart 2: Compression Ratio vs Error Scatter Plot
        results_2200 = all_results['2200']
        optimal_2200 = recommendations['2200']['optimal_ratio']
        
        compression_ratios = [r['compression_ratio'] for r in results_2200]
        errors_pct = []
        for r in results_2200:
            estimated = r['content_kb_uncompressed'] / optimal_2200
            error = abs((estimated - r['real_pages']) / r['real_pages']) * 100
            errors_pct.append(error)
        
        fig, ax = plt.subplots(figsize=(12, 8))
        
        colors = ['green' if e < 10 else 'orange' if e < 20 else 'red' for e in errors_pct]
        
        scatter = ax.scatter(compression_ratios, errors_pct, c=colors, alpha=0.5, s=30)
        ax.axhline(10, color='green', linestyle='--', linewidth=1, label='10% error threshold')
        ax.axvline(3.5, color='purple', linestyle='--', linewidth=1, label='Compression threshold (3.5)')
        
        ax.set_xlabel('Compression Ratio (Uncompressed / Compressed)', fontsize=12)
        ax.set_ylabel('Absolute Error (%)', fontsize=12)
        ax.set_title('Compression Ratio vs Estimation Error\n(2200 chars/page standard)', fontsize=14, fontweight='bold')
        ax.set_ylim(0, min(100, max(errors_pct)))
        
        green_patch = mpatches.Patch(color='green', label='< 10% error')
        orange_patch = mpatches.Patch(color='orange', label='10-20% error')
        red_patch = mpatches.Patch(color='red', label='> 20% error')
        ax.legend(handles=[green_patch, orange_patch, red_patch], loc='upper right')
        
        ax.grid(True, alpha=0.3)
        plt.tight_layout()
        plt.savefig(output_dir / '02_compression_vs_error.png', dpi=150, bbox_inches='tight')
        safe_print("  Created: 02_compression_vs_error.png")
        plt.close()
        
        # Chart 3: Accuracy Comparison Across Standards
        fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(14, 6))
        fig.suptitle('Accuracy Comparison Across Standards', fontsize=14, fontweight='bold')
        
        std_labels = ['1800\n(~250 words)', '2200\n(~300 words)', '2500\n(~350 words)']
        median_errors = [recommendations[s]['stats']['median_abs_error'] for s in ['1800', '2200', '2500']]
        within_10 = [recommendations[s]['stats']['under_10pct'] for s in ['1800', '2200', '2500']]
        within_15 = [recommendations[s]['stats']['under_15pct'] for s in ['1800', '2200', '2500']]
        
        bars1 = ax1.bar(std_labels, median_errors, color=['#3498db', '#2ecc71', '#e74c3c'])
        ax1.set_ylabel('Median Absolute Error (%)', fontsize=11)
        ax1.set_title('Median Error by Standard')
        ax1.grid(True, axis='y', alpha=0.3)
        
        for bar, val in zip(bars1, median_errors):
            height = bar.get_height()
            ax1.text(bar.get_x() + bar.get_width()/2., height,
                    f'{val:.1f}%', ha='center', va='bottom', fontweight='bold')
        
        x = np.arange(len(std_labels))
        width = 0.35
        
        bars2 = ax2.bar(x - width/2, within_10, width, label='Within ±10%', color='#2ecc71')
        bars3 = ax2.bar(x + width/2, within_15, width, label='Within ±15%', color='#3498db')
        
        ax2.set_ylabel('Percentage of Books', fontsize=11)
        ax2.set_title('Accuracy Achievement by Standard')
        ax2.set_xticks(x)
        ax2.set_xticklabels(std_labels)
        ax2.legend()
        ax2.grid(True, axis='y', alpha=0.3)
        
        for bars in [bars2, bars3]:
            for bar in bars:
                height = bar.get_height()
                ax2.text(bar.get_x() + bar.get_width()/2., height,
                        f'{height:.0f}%', ha='center', va='bottom', fontsize=9)
        
        plt.tight_layout()
        plt.savefig(output_dir / '03_standards_comparison.png', dpi=150, bbox_inches='tight')
        safe_print("  Created: 03_standards_comparison.png")
        plt.close()
        
        # Chart 4: Cumulative Error Distribution
        fig, ax = plt.subplots(figsize=(12, 8))
        
        for std_name in ['1800', '2200', '2500']:
            results = all_results[std_name]
            optimal_ratio = recommendations[std_name]['optimal_ratio']
            stats = calculate_error_stats(results, optimal_ratio)
            errors = sorted(stats['all_errors'])
            
            cumulative = np.arange(1, len(errors) + 1) / len(errors) * 100
            
            ax.plot(errors, cumulative, label=f'{std_name} chars/page', linewidth=2)
        
        ax.axvline(10, color='green', linestyle='--', linewidth=1, alpha=0.5, label='10% error')
        ax.axvline(15, color='orange', linestyle='--', linewidth=1, alpha=0.5, label='15% error')
        ax.axhline(90, color='gray', linestyle=':', linewidth=1, alpha=0.5)
        
        ax.set_xlabel('Absolute Error (%)', fontsize=12)
        ax.set_ylabel('Cumulative Percentage of Books', fontsize=12)
        ax.set_title('Cumulative Error Distribution', fontsize=14, fontweight='bold')
        ax.set_xlim(0, 30)
        ax.legend(loc='lower right')
        ax.grid(True, alpha=0.3)
        
        plt.tight_layout()
        plt.savefig(output_dir / '04_cumulative_error.png', dpi=150, bbox_inches='tight')
        safe_print("  Created: 04_cumulative_error.png")
        plt.close()
        
        # Chart 5: Book Size vs Error
        results_2200 = all_results['2200']
        optimal_2200 = recommendations['2200']['optimal_ratio']
        
        page_counts = [r['real_pages'] for r in results_2200]
        errors_by_size = []
        for r in results_2200:
            estimated = r['content_kb_uncompressed'] / optimal_2200
            error = abs((estimated - r['real_pages']) / r['real_pages']) * 100
            errors_by_size.append(error)
        
        fig, ax = plt.subplots(figsize=(12, 8))
        
        colors = ['green' if e < 10 else 'orange' if e < 20 else 'red' for e in errors_by_size]
        ax.scatter(page_counts, errors_by_size, c=colors, alpha=0.5, s=30)
        
        ax.axhline(10, color='green', linestyle='--', linewidth=1, label='10% error threshold')
        ax.set_xlabel('Book Size (pages)', fontsize=12)
        ax.set_ylabel('Absolute Error (%)', fontsize=12)
        ax.set_title('Book Size vs Estimation Error\n(2200 chars/page standard)', 
                     fontsize=14, fontweight='bold')
        ax.set_ylim(0, min(50, max(errors_by_size)))
        
        green_patch = mpatches.Patch(color='green', label='< 10% error')
        orange_patch = mpatches.Patch(color='orange', label='10-20% error')
        red_patch = mpatches.Patch(color='red', label='> 20% error')
        ax.legend(handles=[green_patch, orange_patch, red_patch], loc='upper right')
        
        ax.grid(True, alpha=0.3)
        plt.tight_layout()
        plt.savefig(output_dir / '05_size_vs_error.png', dpi=150, bbox_inches='tight')
        safe_print("  Created: 05_size_vs_error.png")
        plt.close()
        
        # Chart 6: Percentile Performance
        fig, ax = plt.subplots(figsize=(12, 8))
        
        percentiles = [50, 75, 90, 95]
        
        for std_name in ['1800', '2200', '2500']:
            results = all_results[std_name]
            optimal_ratio = recommendations[std_name]['optimal_ratio']
            stats = calculate_error_stats(results, optimal_ratio)
            errors = sorted(stats['all_errors'])
            
            perc_values = [errors[int(len(errors) * p / 100)] for p in percentiles]
            ax.plot(percentiles, perc_values, marker='o', linewidth=2, markersize=8, 
                    label=f'{std_name} chars/page')
        
        ax.set_xlabel('Percentile', fontsize=12)
        ax.set_ylabel('Error (%) at Percentile', fontsize=12)
        ax.set_title('Error at Different Percentiles', fontsize=14, fontweight='bold')
        ax.legend()
        ax.grid(True, alpha=0.3)
        ax.set_xticks(percentiles)
        ax.set_xticklabels([f'{p}th' for p in percentiles])
        
        plt.tight_layout()
        plt.savefig(output_dir / '06_percentile_performance.png', dpi=150, bbox_inches='tight')
        safe_print("  Created: 06_percentile_performance.png")
        plt.close()
        
        safe_print(f"\nAll visualizations saved to: {output_dir.absolute()}")
        return True
        
    except Exception as e:
        safe_print(f"\nChart generation error: {e}")
        return False

def main():
    parser = argparse.ArgumentParser(description='Analyze EPUB page count estimation accuracy')
    parser.add_argument('directory', nargs='?', default='.', help='Directory containing EPUB files')
    parser.add_argument('--charts', action='store_true', help='Generate visualization charts')
    
    args = parser.parse_args()
    
    directory = args.directory
    generate_charts = args.charts
    
    safe_print("="*80)
    safe_print("EPUB PAGE COUNT HEURISTIC ANALYZER")
    safe_print("="*80)
    safe_print(f"\nBook directory: {Path(directory).absolute()}")
    safe_print(f"Script directory: {get_script_directory()}")
    if generate_charts:
        if PLOTTING_AVAILABLE:
            safe_print("Chart generation: enabled")
            safe_print(f"Output directory: {get_script_directory() / 'epub_analysis_charts'}")
        else:
            safe_print("Chart generation: disabled (libraries not available)")
    else:
        safe_print("Chart generation: disabled")
    
    epub_files = list(Path(directory).rglob("*.epub"))
    safe_print(f"\nFound {len(epub_files)} EPUB files")
    
    standards = {
        '1800': {'chars': 1800, 'desc': '~250 words/page'},
        '2200': {'chars': 2200, 'desc': '~300 words/page'},
        '2500': {'chars': 2500, 'desc': '~350 words/page'}
    }
    
    all_results = {}
    
    for std_name, std_info in standards.items():
        safe_print(f"\nAnalyzing {std_name} chars/page standard...")
        results = []
        
        for i, epub in enumerate(epub_files):
            if i % 50 == 0:
                safe_print(f"  Processing {i}/{len(epub_files)}...")
            
            res = analyze_epub(str(epub), std_info['chars'])
            if res:
                results.append(res)
        
        all_results[std_name] = results
        safe_print(f"  Valid books: {len(results)}")
    
    # Analysis
    safe_print("\n" + "="*80)
    safe_print("OPTIMAL STATIC RATIOS")
    safe_print("="*80)
    
    test_ratios = [round(x * 0.1, 1) for x in range(15, 40)]
    
    recommendations = {}
    
    for std_name, results in all_results.items():
        std_info = standards[std_name]
        safe_print(f"\n{std_name} chars/page ({std_info['desc']})")
        safe_print(f"Books analyzed: {len(results)}")
        
        optimal, ratio_stats = find_optimal_ratio(results, test_ratios)
        optimal_stats = ratio_stats[optimal]
        
        safe_print(f"Optimal ratio: {optimal} KB/page")
        safe_print(f"  Median error: {optimal_stats['median_abs_error']:.1f}%")
        safe_print(f"  Mean error: {optimal_stats['mean_abs_error']:.1f}%")
        safe_print(f"  Within ±10%: {optimal_stats['under_10pct']:.1f}%")
        safe_print(f"  Within ±15%: {optimal_stats['under_15pct']:.1f}%")
        safe_print(f"  90th percentile: {optimal_stats['p90_abs_error']:.1f}%")
        
        recommendations[std_name] = {
            'optimal_ratio': optimal,
            'stats': optimal_stats
        }
    
    # Compression analysis
    safe_print("\n" + "="*80)
    safe_print("COMPRESSION RATIO ANALYSIS")
    safe_print("="*80)
    
    results_2200 = all_results['2200']
    optimal_2200 = recommendations['2200']['optimal_ratio']
    
    safe_print(f"\nUsing 2200 chars/page standard (ratio: {optimal_2200} KB/page)")
    
    comp_groups = analyze_compression_correlation(results_2200, optimal_2200)
    
    safe_print("\nError by compression group:")
    safe_print(f"{'Group':<15} | {'Count':<6} | {'Avg Ratio':<10} | {'Median Err %':<12}")
    safe_print("-" * 60)
    
    for group_name, data in comp_groups.items():
        safe_print(f"{group_name:<15} | {data['count']:<6} | "
                  f"{data['avg_ratio']:<10.2f} | "
                  f"{data['stats']['median_abs_error']:<12.1f}")
    
    high_error = comp_groups.get('high (>=4.0)', {}).get('stats', {}).get('median_abs_error', 0)
    mid_error = comp_groups.get('mid (3.0-4.0)', {}).get('stats', {}).get('median_abs_error', 0)
    
    if high_error > mid_error + 5:
        safe_print("\nCompression correlation detected")
        safe_print("Testing adjustment factors...")
        
        adjustment_factors = [0.2, 0.3, 0.4, 0.5, 0.6]
        best_factor, factor_results = test_compression_adjustment(
            results_2200, optimal_2200, adjustment_factors
        )
        
        safe_print(f"\n{'Factor':<8} | {'Median Err %':<12} | {'Overall Δ':<12} | {'Overall Δ%':<12}")
        safe_print("-" * 60)
        for factor in adjustment_factors:
            res = factor_results[factor]
            safe_print(f"{factor:<8.1f} | {res['median_error']:<12.1f} | "
                      f"{res['improvement']:<12.1f} | {res['improvement_pct']:<12.1f}%")
        
        safe_print(f"\nOptimal adjustment factor: {best_factor}")
        
        # Per-group analysis
        safe_print("\n" + "="*80)
        safe_print("PER-GROUP IMPROVEMENT ANALYSIS")
        safe_print("="*80)
        
        best_result = factor_results[best_factor]
        group_improvements = best_result['group_improvements']
        
        total_books = len(results_2200)
        low_count = len([r for r in results_2200 if r['compression_ratio'] < 3.0])
        mid_count = len([r for r in results_2200 if 3.0 <= r['compression_ratio'] < 4.0])
        high_count = len([r for r in results_2200 if r['compression_ratio'] >= 4.0])
        
        safe_print(f"\n{'Group':<15} | {'Count':<6} | {'% Library':<10} | {'Before':<10} | {'After':<10} | {'Δ Error':<10} | {'Δ %':<10}")
        safe_print("-" * 90)
        
        for group_name, count, pct in [
            ('Low (<3.0)', low_count, low_count/total_books*100),
            ('Mid (3-4)', mid_count, mid_count/total_books*100),
            ('High (>=4)', high_count, high_count/total_books*100)
        ]:
            group_key = group_name.split()[0].lower()
            if group_key in group_improvements:
                gi = group_improvements[group_key]
                safe_print(f"{group_name:<15} | {count:<6} | {pct:<10.1f} | "
                          f"{gi['before']:<10.1f} | {gi['after']:<10.1f} | "
                          f"{gi['improvement']:<10.1f} | {gi['improvement_pct']:<10.1f}")
        
        safe_print("\nNote: Overall median dominated by largest group.")
        safe_print("Compression adjustment benefits high-compression outliers.")
        
    else:
        safe_print("\nNo significant compression correlation detected")
        best_factor = None
    
    # Generate visualizations
    if generate_charts:
        safe_print("\n" + "="*80)
        safe_print("GENERATING VISUALIZATIONS")
        safe_print("="*80)
        
        create_visualizations(all_results, standards, recommendations)
    
    # Final recommendations
    safe_print("\n" + "="*80)
    safe_print("KOREADER PATCH CALIBRATION VALUES")
    safe_print("="*80)
    
    safe_print("\nBase ratios:")
    for std_name in ['1800', '2200', '2500']:
        rec = recommendations[std_name]
        var_name = f"RATIO_{std_name}_CHARS"
        safe_print(f"  {var_name} = {rec['optimal_ratio']}")
    
    if best_factor and high_error > mid_error + 5:
        safe_print(f"\nCompression adjustment:")
        safe_print(f"  ENABLE_COMPRESSION = true")
        safe_print(f"  COMPRESSION_THRESHOLD = 3.5")
        safe_print(f"  COMPRESSION_BASELINE = 3.0")
        safe_print(f"  COMPRESSION_FACTOR = {best_factor}")
    else:
        safe_print(f"\nCompression adjustment:")
        safe_print(f"  ENABLE_COMPRESSION = false")
    
    safe_print("\nAccuracy metrics:")
    safe_print(f"  ACCURACY_MEDIAN_ERROR = {recommendations['2200']['stats']['median_abs_error']:.1f}")
    safe_print(f"  ACCURACY_WITHIN_10PCT = {recommendations['2200']['stats']['under_10pct']:.0f}")
    safe_print(f"  ACCURACY_WITHIN_15PCT = {recommendations['2200']['stats']['under_15pct']:.0f}")
    
    safe_print("\n" + "="*80)
    safe_print("Analysis complete")
    safe_print("="*80)

if __name__ == "__main__":
    main()
