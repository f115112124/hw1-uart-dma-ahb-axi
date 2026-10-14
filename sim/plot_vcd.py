"""Render selected *actual* VCD transitions to small standalone SVG waveforms.

Standard-library only. Run run_all.py first, then this script from any directory.
The raw VCD remains the authoritative full waveform; these SVGs show a window.
"""
from bisect import bisect_right
from dataclasses import dataclass
from html import escape
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]


@dataclass
class Signal:
    name: str
    code: str
    width: int


def read_vcd(path):
    content = path.read_text(encoding='utf-8', errors='replace')
    scale_match = re.search(r'\$timescale\s+(\d+)\s*(s|ms|us|ns|ps|fs)\s+\$end', content)
    if scale_match:
        amount, unit = scale_match.groups()
        scale_ns = int(amount) * {'s':1e9,'ms':1e6,'us':1e3,'ns':1,'ps':1e-3,'fs':1e-6}[unit]
    else:
        raise ValueError(f'No VCD timescale: {path}')
    signals, changes, scope = [], {}, []
    tick, in_header = 0, True
    for raw in content.splitlines():
        line = raw.strip()
        if in_header:
            if line.startswith('$scope '):
                scope.append(line.split()[2])
            elif line.startswith('$upscope'):
                scope.pop()
            elif line.startswith('$var '):
                fields = line.split()
                width, code, leaf = int(fields[2]), fields[3], fields[4]
                signals.append(Signal('.'.join([*scope,leaf]),code,width))
                changes.setdefault(code,[])
            elif line.startswith('$enddefinitions'):
                in_header=False
            continue
        if not line or line.startswith('$'):
            continue
        if line.startswith('#'):
            tick=int(line[1:])
        elif line[0] in 'bB':
            fields=line[1:].split()
            if len(fields)==2 and fields[1] in changes:
                changes[fields[1]].append((tick,fields[0].lower()))
        elif line[0] in '01xXzZ' and line[1:] in changes:
            changes[line[1:]].append((tick,line[0].lower()))
    return signals,changes,scale_ns,tick


def normalized(value):
    return value.lower().replace('_','')


def pick(signals,names):
    for name in names:
        matches=[s for s in signals if normalized(s.name.rsplit('.',1)[-1])==normalized(name)]
        if matches:
            return min(matches,key=lambda s:(s.name.count('.'),len(s.name)))
    return None


def number(value):
    try:
        return int(value,2)
    except ValueError:
        return None


def fmt_value(value,width):
    result=number(value)
    if result is None:
        return value.upper()
    if width<=4:
        return str(result)
    return f'0x{result:0{(width+3)//4}X}'


def value_at(events,tick):
    index=bisect_right([t for t,_ in events],tick)-1
    return events[index][1] if index>=0 else 'x'


def render(kind,signals,changes,scale_ns,final_tick,output):
    configs={
        'uart':(['clk'],['uart_tx'],['uart_rx'],['cmd_valid','dma_cmd_valid'],
                ['cmd_write','dma_cmd_write'],['dma_busy'],['dma_done'],['sticky_error']),
        'ahb':(['clk'],['haddr'],['htrans'],['hwrite'],['hwdata'],['hrdata'],['hready'],['hresp']),
        'axi':(['clk'],['araddr'],['arvalid'],['arready'],['arlen'],['rvalid'],['rready'],['rlast'])}
    selected=[pick(signals,names) for names in configs[kind]]
    selected=[s for s in selected if s is not None]
    if len(selected)<3:
        raise ValueError(f'Too few matching signals for {kind}: {[s.name for s in selected]}')
    clock=pick(signals,['clk'])
    rising=[t for t,v in changes[clock.code] if v=='1'] if clock else []
    period=rising[1]-rising[0] if len(rising)>1 else max(1,round(10/scale_ns))
    anchor=0
    if kind=='uart':
        signal=pick(signals,['uart_tx'])
        anchor=next((t for t,v in changes[signal.code] if v=='0' and t>period*8),0)
    elif kind=='ahb':
        signal=pick(signals,['hburst'])
        if signal:
            anchor=next((t for t,v in changes[signal.code] if number(v)==3),0)
    else:
        signal=pick(signals,['arlen'])
        address_valid=pick(signals,['arvalid'])
        if signal and address_valid:
            anchor=next((t for t,v in changes[address_valid.code]
                         if v=='1' and number(value_at(changes[signal.code],t))==3),0)
    begin=max(0,anchor-6*period)
    end=min(final_tick,begin+({'uart':340,'ahb':70,'axi':90}[kind])*period)
    if end<=begin:
        end=begin+period
    left,right,width=230,980,1000
    top,row_h=110,70
    height=top+row_h*len(selected)+58
    span=end-begin
    def x(t):
        return left+(t-begin)/span*(right-left)
    svg=[f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}">',
         '<rect width="100%" height="100%" fill="#f8fafc"/>',
         '<style>text{font-family:Consolas,monospace;fill:#20324a}.label{font-size:16px}.value{font-size:15px}.hierarchy{font-size:12px;fill:#64748b}.title{font-family:Arial,sans-serif;font-size:24px;font-weight:bold}</style>',
         f'<text class="title" x="24" y="33">{kind.upper()} — Actual simulation waveform</text>',
         f'<text class="label" x="24" y="59">Source: results/tb_{"uart_dma" if kind=="uart" else kind}.vcd | Clock period: {period*scale_ns:g} ns</text>',
         '<text class="label" x="24" y="85">Absolute simulation time (ns). Vector labels show hexadecimal values.</text>']
    for i in range(11):
        tick=begin+span*i/10
        at=x(tick)
        svg += [f'<line x1="{at:.2f}" y1="{top-5}" x2="{at:.2f}" y2="{height-36}" stroke="#dbe3ec"/>',
                f'<text class="value" x="{at:.2f}" y="{height-16}" text-anchor="middle">{tick*scale_ns:g}</text>']
    for index,signal in enumerate(selected):
        y=top+index*row_h
        leaf=signal.name.rsplit('.',1)[-1]
        svg.append(f'<text class="label" x="24" y="{y+21}">{escape(leaf)} [{signal.width}]</text>')
        # Keep the hierarchical identity visible so identical leaf names are unambiguous.
        hierarchy=signal.name.rsplit('.',1)[0]
        if len(hierarchy)>29:
            hierarchy='…'+hierarchy[-28:]
        svg.append(f'<text class="hierarchy" x="24" y="{y+41}">{escape(hierarchy)}</text>')
        events=changes[signal.code]
        window=[(begin,value_at(events,begin))]
        window += [(t,v) for t,v in events if begin<t<end]
        window.append((end,window[-1][1]))
        if signal.width==1:
            prev_y=None
            for j in range(len(window)-1):
                t,value=window[j]
                next_t=window[j+1][0]
                line_y=y+10 if value=='1' else y+38 if value=='0' else y+24
                color='#087e8b' if value in ('0','1') else '#c24f35'
                if prev_y is not None and prev_y!=line_y:
                    svg.append(f'<line x1="{x(t):.2f}" y1="{prev_y}" x2="{x(t):.2f}" y2="{line_y}" stroke="{color}" stroke-width="1.5"/>')
                svg.append(f'<line x1="{x(t):.2f}" y1="{line_y}" x2="{x(next_t):.2f}" y2="{line_y}" stroke="{color}" stroke-width="1.5"/>')
                prev_y=line_y
        else:
            for j in range(len(window)-1):
                t,value=window[j]
                next_t=window[j+1][0]
                x1,x2=x(t),x(next_t)
                svg.append(f'<path d="M{x1:.2f},{y+24} L{x1+2:.2f},{y+10} L{x2-2:.2f},{y+10} L{x2:.2f},{y+24} L{x2-2:.2f},{y+38} L{x1+2:.2f},{y+38} Z" fill="#e1eefa" stroke="#386b9b"/>')
                label=fmt_value(value,signal.width)
                if x2-x1>len(label)*8+8:
                    svg.append(f'<text class="value" x="{(x1+x2)/2:.2f}" y="{y+28}" text-anchor="middle">{escape(label)}</text>')
        svg.append(f'<line x1="16" y1="{y+51}" x2="{right}" y2="{y+51}" stroke="#e9edf3"/>')
    svg.append('</svg>')
    output.write_text('\n'.join(svg),encoding='utf-8')
    print(f'{output.name}: {begin*scale_ns:g}-{end*scale_ns:g} ns; '+', '.join(s.name for s in selected))


def main():
    for kind,filename in [('uart','tb_uart_dma.vcd'),('ahb','tb_ahb.vcd'),('axi','tb_axi.vcd')]:
        path=ROOT/'results'/filename
        if not path.is_file():
            print(f'SKIP: missing {path.name}; run sim/run_all.py first')
            continue
        render(kind,*read_vcd(path),ROOT/'diagrams'/f'wave_{kind}.svg')


if __name__=='__main__':
    main()
