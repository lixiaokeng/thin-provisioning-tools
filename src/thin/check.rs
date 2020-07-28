use anyhow::{anyhow, Result};
use nom::{bytes::complete::*, number::complete::*, IResult};
use std::collections::HashSet;
use std::error::Error;
use std::path::Path;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use crate::block_manager::{Block, IoEngine, AsyncIoEngine, SyncIoEngine, BLOCK_SIZE};
use crate::checksum;
use crate::thin::superblock::*;

trait ValueType {
    type Value;
    fn unpack(data: &[u8]) -> IResult<&[u8], Self::Value>;
}

struct NodeHeader {
    is_leaf: bool,
    block: u64,
    nr_entries: u32,
    max_entries: u32,
    value_size: u32,
}

const INTERNAL_NODE: u32 = 1;
const LEAF_NODE: u32 = 2;

fn unpack_node_header(data: &[u8]) -> IResult<&[u8], NodeHeader> {
    let (i, _csum) = le_u32(data)?;
    let (i, flags) = le_u32(i)?;
    let (i, block) = le_u64(i)?;
    let (i, nr_entries) = le_u32(i)?;
    let (i, max_entries) = le_u32(i)?;
    let (i, value_size) = le_u32(i)?;
    let (i, _padding) = le_u32(i)?;

    Ok((
        i,
        NodeHeader {
            is_leaf: flags == LEAF_NODE,
            block,
            nr_entries,
            max_entries,
            value_size,
        },
    ))
}

enum Node<V: ValueType> {
    Internal {
        header: NodeHeader,
        keys: Vec<u64>,
        values: Vec<u64>,
    },
    Leaf {
        header: NodeHeader,
        keys: Vec<u64>,
        values: Vec<V::Value>,
    },
}

fn unpack_node_<V: ValueType>(data: &[u8]) -> IResult<&[u8], Node<V>> {
    use nom::multi::count;

    let (i, header) = unpack_node_header(data)?;
    let (i, keys) = count(le_u64, header.nr_entries as usize)(i)?;

    let nr_free = header.max_entries - header.nr_entries;
    let (i, _padding) = count(le_u64, nr_free as usize)(i)?;

    if header.is_leaf {
        let (i, values) = count(V::unpack, header.nr_entries as usize)(i)?;
        Ok((
            i,
            Node::Leaf {
                header,
                keys,
                values,
            },
        ))
    } else {
        let (i, values) = count(le_u64, header.nr_entries as usize)(i)?;
        Ok((
            i,
            Node::Internal {
                header,
                keys,
                values,
            },
        ))
    }
}

fn unpack_node<V: ValueType>(data: &[u8]) -> Result<Node<V>> {
    if let Ok((_i, node)) = unpack_node_(data) {
        Ok(node)
    } else {
        Err(anyhow!("couldn't unpack btree node"))
    }
}

struct ValueU64;

impl ValueType for ValueU64 {
    type Value = u64;
    fn unpack(i: &[u8]) -> IResult<&[u8], u64> {
        le_u64(i)
    }
}

struct BlockTime {
    block: u64,
    time: u32,
}

struct ValueBlockTime;

impl ValueType for ValueBlockTime {
    type Value = BlockTime;
    fn unpack(i: &[u8]) -> IResult<&[u8], BlockTime> {
        let (i, n) = le_u64(i)?;
        let block = n >> 24;
        let time = n & ((1 << 24) - 1);

        Ok((
            i,
            BlockTime {
                block,
                time: time as u32,
            },
        ))
    }
}

#[derive(Copy, Clone)]
enum MappingLevel {
    Top,
    Bottom,
}

fn walk_nodes<E: IoEngine>(
    engine: &mut E,
    seen: &mut HashSet<u64>,
    level: MappingLevel,
    bs: &Vec<u64>,
) -> Result<()> {
    let mut blocks = Vec::new();
    for b in bs {
        if !seen.contains(b) {
            blocks.push(Block::new(*b));
        }
    }

    engine.read_many(&mut blocks)?;

    for b in blocks {
        walk_node(engine, seen, level, &b);
    }

    Ok(())
}

fn walk_node<E: IoEngine>(
    engine: &mut E,
    seen: &mut HashSet<u64>,
    level: MappingLevel,
    b: &Block,
) -> Result<()> {
    seen.insert(b.loc);

    let bt = checksum::metadata_block_type(b.get_data());
    if bt != checksum::BT::NODE {
        return Err(anyhow!("checksum failed for node {}, {:?}", b.loc, bt));
    }

    match level {
        MappingLevel::Top => {
            let node = unpack_node::<ValueU64>(&b.get_data())?;
            match node {
                Node::Leaf {
                    header: header,
                    keys: _keys,
                    values,
                } => {
                    walk_nodes(engine, seen, MappingLevel::Bottom, &values)?;
                }
                Node::Internal {
                    header: header,
                    keys: _keys,
                    values,
                } => {
                    walk_nodes(engine, seen, MappingLevel::Top, &values)?;
                }
            }
        }
        MappingLevel::Bottom => {
            let node = unpack_node::<ValueBlockTime>(&b.get_data())?;
            match node {
                Node::Leaf {
                    header: header,
                    keys: _keys,
                    values,
                } => {
                    // FIXME: check in bounds
                }
                Node::Internal {
                    header: header,
                    keys: _keys,
                    values,
                } => {
                    walk_nodes(engine, seen, MappingLevel::Bottom, &values)?;
                }
            }
        }
    }

    Ok(())
}

pub fn check(dev: &Path) -> Result<()> {
    //let mut engine = SyncIoEngine::new(dev)?;
    let mut engine = AsyncIoEngine::new(dev, 256)?;

    let now = Instant::now();
    let sb = read_superblock(&mut engine, SUPERBLOCK_LOCATION)?;
    eprintln!("{:?}", sb);
    let mut seen = HashSet::new();

    let mut root = Block::new(sb.mapping_root);
    engine.read(&mut root)?;

    walk_node(&mut engine, &mut seen, MappingLevel::Top, &root)?;
    println!(
        "read mapping tree in {} ms",
        now.elapsed().as_millis()
    );

    Ok(())
}
