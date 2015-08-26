{-# LANGUAGE FlexibleContexts #-}

module Propellor.Property.Parted (
	TableType(..),
	PartTable(..),
	Partition(..),
	mkPartition,
	Partition.Fs(..),
	ByteSize,
	Partition.MkfsOpts,
	PartType(..),
	PartFlag(..),
	Eep(..),
	partitioned,
	parted,
	installed,
) where

import Propellor
import qualified Propellor.Property.Apt as Apt
import qualified Propellor.Property.Partition as Partition
import Utility.DataUnits
import Data.Char
import System.Posix.Files

class PartedVal a where
	val :: a -> String

-- | Types of partition tables supported by parted.
data TableType = MSDOS | GPT | AIX | AMIGA | BSD | DVH | LOOP | MAC | PC98 | SUN
	deriving (Show)

instance PartedVal TableType where
	val = map toLower . show

-- | A disk's partition table.
data PartTable = PartTable TableType [Partition]
	deriving (Show)

instance Monoid PartTable where
	-- | default TableType is MSDOS
	mempty = PartTable MSDOS []
	-- | uses the TableType of the second parameter
	mappend (PartTable _l1 ps1) (PartTable l2 ps2) = PartTable l2 (ps1 ++ ps2)

-- | A partition on the disk.
data Partition = Partition
	{ partType :: PartType
	, partSize :: ByteSize -- ^ size of the partition in bytes
	, partFs :: Partition.Fs
	, partMkFsOpts :: Partition.MkfsOpts
	, partFlags :: [(PartFlag, Bool)] -- ^ flags can be set or unset (parted may set some flags by default)
	, partName :: Maybe String -- ^ optional name for partition (only works for GPT, PC98, MAC)
	}
	deriving (Show)

-- | Makes a Partition with defaults for non-important values.
mkPartition :: Partition.Fs -> ByteSize -> Partition
mkPartition fs sz = Partition
	{ partType = Primary
	, partSize = sz
	, partFs = fs
	, partMkFsOpts = []
	, partFlags = []
	, partName = Nothing
	}

-- | Type of a partition.
data PartType = Primary | Logical | Extended
	deriving (Show)

instance PartedVal PartType where
	val Primary = "primary"
	val Logical = "logical"
	val Extended = "extended"

-- | Flags that can be set on a partition.
data PartFlag = BootFlag | RootFlag | SwapFlag | HiddenFlag | RaidFlag | LvmFlag | LbaFlag | LegacyBootFlag | IrstFlag | EspFlag | PaloFlag
	deriving (Show)

instance PartedVal PartFlag where
	val BootFlag = "boot"
	val RootFlag = "root"
	val SwapFlag = "swap"
	val HiddenFlag = "hidden"
	val RaidFlag = "raid"
	val LvmFlag = "lvm"
	val LbaFlag = "lba"
	val LegacyBootFlag = "legacy_boot"
	val IrstFlag = "irst"
	val EspFlag = "esp"
	val PaloFlag = "palo"

instance PartedVal Bool where
	val True = "on"
	val False = "off"

instance PartedVal Partition.Fs where
	val Partition.EXT2 = "ext2"
	val Partition.EXT3 = "ext3"
	val Partition.EXT4 = "ext4"
	val Partition.BTRFS = "btrfs"
	val Partition.REISERFS = "reiserfs"
	val Partition.XFS = "xfs"
	val Partition.FAT = "fat"
	val Partition.VFAT = "vfat"
	val Partition.NTFS = "ntfs"
	val Partition.LinuxSwap = "linux-swap"

data Eep = YesReallyDeleteDiskContents

-- | Partitions a disk using parted, and formats the partitions.
--
-- The FilePath can be a block device (eg, \/dev\/sda), or a disk image file.
--
-- This deletes any existing partitions in the disk! Use with EXTREME caution!
partitioned :: Eep -> FilePath -> PartTable -> Property NoInfo
partitioned eep disk (PartTable tabletype parts) = property desc $ do
	isdev <- liftIO $ isBlockDevice <$> getFileStatus disk
	ensureProperty $ if isdev
		then go (map (\n -> disk ++ show n) [1 :: Int ..])
		else Partition.kpartx disk go
  where
	desc = disk ++ " partitioned"
	go devs = combineProperties desc $
		parted eep disk partedparams : map format (zip parts devs)
	partedparams = concat $ mklabel : mkparts (1 :: Integer) 0 parts []
	format (p, dev) = Partition.formatted' (partMkFsOpts p)
		Partition.YesReallyFormatPartition (partFs p) dev
	mklabel = ["mklabel", val tabletype]
	mkflag partnum (f, b) =
		[ "set"
		, show partnum
		, val f
		, val b
		]
	mkpart partnum offset p =
		[ "mkpart"
		, val (partType p)
		, val (partFs p)
		-- Using 0 rather than 0B is undocumented magic;
		-- it makes parted automatically adjust the first partition
		-- start to be beyond the start of the partition table.
		, if offset == 0 then "0" else show offset ++ "B"
		, show (offset + partSize p) ++ "B"
		] ++ case partName p of
			Just n -> ["name", show partnum, n]
			Nothing -> []
	mkparts partnum offset (p:ps) c = 
		mkparts (partnum+1) (offset + partSize p) ps
			(c ++ mkpart partnum offset p : map (mkflag partnum) (partFlags p))
	mkparts _ _ [] c = c

-- | Runs parted on a disk with the specified parameters.
--
-- Parted is run in script mode, so it will never prompt for input.
-- It is asked to use cylinder alignment for the disk.
parted :: Eep -> FilePath -> [String] -> Property NoInfo
parted YesReallyDeleteDiskContents disk ps = 
	cmdProperty "parted" ("--script":"--align":"cylinder":disk:ps)
		`requires` installed

-- | Gets parted installed.
installed :: Property NoInfo
installed = Apt.installed ["parted"]
