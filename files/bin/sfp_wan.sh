#!/bin/sh


LOCK_FILE=/tmp/sfp_wan.lock

########################  PLATFORMSETUP START
GPIOBASE=`cat /sys/class/gpio/gpiochip*/base | head -n1`
set_gpio() {
  GPIO_PIN=`expr $1 + $GPIOBASE`
  if [ -d /sys/class/gpio/gpio$GPIO_PIN ]; then
    echo "pin${GPIO_PIN} already be exported."
  else
    echo $GPIO_PIN > /sys/class/gpio/export;
    if [ $? != 0 ]; then
      echo "export pin${GPIO_PIN} fail."
    fi
  fi

  if [ "$3" != "" ]; then
    { [ "$3" = "0" ] && echo "low" || echo "high"; } \
      >"/sys/class/gpio/gpio$GPIO_PIN/direction"
  else
    echo in > /sys/class/gpio/gpio$GPIO_PIN/direction
  fi
}
# SFP: AE_MOD_ABS_1V8(GPIO_57), AE_RX_LOS_3V3(GPIO_23), AE_TX_FAULT_3V3(GPIO_28)
GPIO_INPUT_LIST="23 28 57"
# SFP: SFP_EWAN_SEL GPIO 10, HIGH for 2.5G PHY, LOW for SFP
GPIO_OUT_H_LIST="10"
# SFP: AE_TX_DIS_3V3(GPIO_26)
GPIO_OUT_L_LIST="26"
function init_sfp_gpios(){
    for i in $GPIO_INPUT_LIST; do
        set_gpio $i in
    done
    for i in $GPIO_OUT_H_LIST; do
        set_gpio $i out 1
    done
    for i in $GPIO_OUT_L_LIST; do
        set_gpio $i out 0
    done
}
########################  PLATFORMSETUP END

# CURRENT_SFP_MODE, 0 is fiber sfp, 1 is copper sfp
CURRENT_SFP_MODE=0
CURRENT_SFP_MODE_IS_FIBER=0
CURRENT_SFP_MODE_IS_COPPER=1
# sometimes SFP need to have more time to boot up, we need to wait additional time for sfp ready.
SFP_CHECK_RETRY_TIME=60

function is_sfp_present(){
    MOD_ABS_VALUE=`cat /sys/class/gpio/gpio468/value`
    if [ "$MOD_ABS_VALUE" = "0" ]; then
        echo 1
    else
        echo 0
    fi
}

function is_sfp_rx_los(){
    RX_LOS_VALUE=`cat /sys/class/gpio/gpio434/value`
    if [ "$RX_LOS_VALUE" = "1" ]; then
        echo 1
    else
        echo 0
    fi
}

# set_sfp_ethwan_sel()
# $1: sfp, ethwan
function set_sfp_ethwan_sel(){
    case "$1" in
        "sfp")
            echo "Switch SGMII1 to SFP Mode"
            echo 0 > /sys/class/gpio/gpio421/value
            ;;
        "ethwan")
            echo "Switch SGMII1 to 2.5G PHY Mode"
            echo 1 > /sys/class/gpio/gpio421/value
            ;;
        *) echo "unknow select"
    esac
}

function init_phy6(){
    # init gpy211 fixed-link 2500base-x
    mdio mdio-bus mmd 6:30 0x0008 0xa4e2

    # setup gpy211 led
    mdio mdio-bus mmd 6:30 0x0001 0x0080
}



if [ -f $LOCK_FILE ]; then
  echo "\n================ This script is already running! lock:  /tmp/sfp_wan.lock \n"
  exit 1
fi

touch $LOCK_FILE

if [ ! -f $LOCK_FILE ]; then
  echo "\n=============== Cannot create lock file!\n"
  exit 1
fi

# Export the pins
init_sfp_gpios

# Init phy6
init_phy6


# wait for system ready
sleep 10

CURRENT_CHECK_TIMES=0
LATEST_SFP_PRESENT=0

while true
do
    SFP_PRESENT=$(is_sfp_present)
    #echo "check CURRENT_SFP_MODE=$CURRENT_SFP_MODE"
    #echo "check SFP_PRESENT=$SFP_PRESENT"
    #echo "LATEST_SFP_PRESENT=$LATEST_SFP_PRESENT"
    if [ "$SFP_PRESENT" = "1" ] && [ "$LATEST_SFP_PRESENT" = "0" ]; then
        echo "sfp module was plug in!"
        LATEST_SFP_PRESENT=1
        set_sfp_ethwan_sel sfp
	# shutdown rj45
        mdio mdio-bus mmd 6:0 0x0000 0x3840

        #wait
        sleep 3

        echo "===== Change to SFP Mode ====="

    elif [ "$SFP_PRESENT" = "0" ] && [ "$LATEST_SFP_PRESENT" = "1" ]; then
        # because the SFP_PRESENT of PMG3000-D20B will HIGH-LOW-HIGH when fiber plug in
        # we donot know why, but I impact the SFP module detect result!
        if [ $CURRENT_CHECK_TIMES -le 3 ]; then
            CURRENT_CHECK_TIMES=$(($CURRENT_CHECK_TIMES+1))
            sleep 1
            continue
        else
            echo "sfp module was removed!"
            LATEST_SFP_PRESENT=0
            set_sfp_ethwan_sel ethwan
            # power up rj45
            mdio mdio-bus mmd 6:0 0x0000 0x3040


            #wait
            sleep 3

            echo "===== Change to 2.5G PHY Mode ====="
        fi
    fi
    if [ $CURRENT_CHECK_TIMES -ne 0 ]; then
        CURRENT_CHECK_TIMES=0
    fi
    sleep 3
done

rm -f ${LOCK_FILE}
