!
! Copyright (C) 2001 PWSCF group
! This file is distributed under the terms of the
! GNU General Public License. See the file `License'
! in the root directory of the present distribution,
! or http://www.gnu.org/copyleft/gpl.txt .
!
!
! Author: L. Martin-Samos
!
!--------------------------------------------------------------------
subroutine stop_pp
  !--------------------------------------------------------------------
  !
  ! Synchronize processes before stopping.
  !
  use control_flags, only: twfcollect
  use io_files, only: iunwfc
  use mp_global,only: mp_global_end
  USE parallel_include
#ifdef __PARA

  integer :: info
  logical :: op

  inquire ( iunwfc, opened = op )

  if ( op ) then
     if (twfcollect) then
        close (unit = iunwfc, status = 'delete')
     else
        close (unit = iunwfc, status = 'keep')
     end if
  end if
#endif

  call mp_global_end()

  stop
end subroutine stop_pp
